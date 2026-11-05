//
//  ScanRenderer.swift
//  StrayScanner
//
//  Preview renderer with selectable view modes (stray-scanner-sf fork):
//  camera, LiDAR depth, camera+depth mix, live point cloud and a dark battery-saving mode.
//

import Foundation
import Metal
import ARKit
import simd

enum ViewMode: Int, CaseIterable {
    case camera = 0
    case depth = 1
    case overlay = 2
    case pointCloud = 3
    case dim = 4
    case map = 5
    /// The PC's live preview splat (trained while you scan), seen from where the phone is now.
    case pcPreview = 6

    /// Order of the view picker (map before dim).
    static let displayOrder: [ViewMode] = [.camera, .depth, .overlay, .pointCloud, .map, .pcPreview, .dim]

    static let userDefaultsKey = "ViewMode"

    var title: String {
        switch self {
        case .camera: return "Camera"
        case .depth: return "Depth"
        case .overlay: return "Mix"
        case .pointCloud: return "Points"
        case .dim: return "Dim"
        case .map: return "Map"
        case .pcPreview: return "PC preview"
        }
    }

    var symbolName: String {
        switch self {
        case .camera: return "camera.fill"
        case .depth: return "dot.radiowaves.left.and.right"
        case .overlay: return "square.on.square"
        case .pointCloud: return "circle.grid.3x3.fill"
        case .dim: return "moon.fill"
        case .map: return "map.fill"
        case .pcPreview: return "desktopcomputer"
        }
    }

    static func load() -> ViewMode {
        guard UserDefaults.standard.object(forKey: userDefaultsKey) != nil else { return .camera }
        let mode = ViewMode(rawValue: UserDefaults.standard.integer(forKey: userDefaultsKey)) ?? .camera
        // Never start in dim mode: it lowers the screen brightness.
        return mode == .dim ? .camera : mode
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: ViewMode.userDefaultsKey)
    }
}

/// Layout must match SFPointUniforms in Shaders.metal.
private struct PointCloudUniforms {
    var viewProjection: simd_float4x4
    var pointScale: Float
    var clipY: Float = .greatestFiniteMagnitude
    var maxPointSize: Float = 12
    var pad0: Float = 0
}

private let quadVertices: [Float] = [
    -1.0, -1.0, 1.0, 1.0,
     1.0, -1.0, 1.0, 0.0,
    -1.0,  1.0, 0.0, 1.0,
     1.0,  1.0, 0.0, 0.0
]

/// A view backed by a CAMetalLayer that keeps the drawable size in sync with its bounds.
final class MetalPreviewView: UIView {
    override class var layerClass: AnyClass { return CAMetalLayer.self }
    var metalLayer: CAMetalLayer { return layer as! CAMetalLayer }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 2× is sharp enough for a preview and draws ~45 % fewer pixels than 3× on Pro phones.
        let scale = min(traitCollection.displayScale, 2.0)
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }
}

final class ScanRenderer {
    let pointCloud: PointCloudAccumulator
    var mode: ViewMode = .camera
    /// Point cloud seen from behind and above the phone (true) or through the camera (false).
    var chaseCamera: Bool = true
    /// Colour the point cloud by how many directions each spot was filmed from.
    var showCoverage: Bool = false
    /// Hide points more than this far above the phone in the overview and minimap (cuts the ceiling away).
    var ceilingCut: Float = 0.3
    /// Small extra views (picture-in-picture), each showing one view mode.
    var insets: [(layer: CAMetalLayer, mode: ViewMode)] = []
    /// Path-guide stripes to draw (world space).
    var guideVertices: [PointCloudVertex] = []
    /// Lighter rendering when the phone is hot.
    var lowPower: Bool = false {
        didSet { pointCloud.lowPower = lowPower }
    }
    private var frameNumber = 0
    /// Draw the main preview every Nth camera frame (2 at 60 fps → 30 fps preview, saves GPU and battery).
    var previewInterval: Int = 2

    private let layer: CAMetalLayer
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let quadBuffer: MTLBuffer
    private let cameraPipeline: MTLRenderPipelineState
    private let depthPipeline: MTLRenderPipelineState
    private let overlayPipeline: MTLRenderPipelineState
    private let pointPipeline: MTLRenderPipelineState
    private let flatPointPipeline: MTLRenderPipelineState
    private let guideBuffer: MTLBuffer
    private let guideCapacity = 4096
    private let depthStencilState: MTLDepthStencilState
    private var depthAttachments: [Int: MTLTexture] = [:]
    private var textureCache: CVMetalTextureCache
    private var clearedForDim = false

    init?(layer: CAMetalLayer) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let quadBuffer = device.makeBuffer(bytes: quadVertices, length: quadVertices.count * MemoryLayout<Float>.size, options: []),
              let pointCloud = PointCloudAccumulator(device: device) else { return nil }
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let textureCache = cache else { return nil }

        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true

        let quadDescriptor = MTLVertexDescriptor()
        quadDescriptor.attributes[0].format = .float2
        quadDescriptor.attributes[0].offset = 0
        quadDescriptor.attributes[0].bufferIndex = 0
        quadDescriptor.attributes[1].format = .float2
        quadDescriptor.attributes[1].offset = 8
        quadDescriptor.attributes[1].bufferIndex = 0
        quadDescriptor.layouts[0].stride = 16
        quadDescriptor.layouts[0].stepRate = 1
        quadDescriptor.layouts[0].stepFunction = .perVertex

        func quadPipeline(_ fragmentName: String) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "drawRectangleFill")
            descriptor.fragmentFunction = library.makeFunction(name: fragmentName)
            descriptor.vertexDescriptor = quadDescriptor
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        let pointDescriptor = MTLRenderPipelineDescriptor()
        pointDescriptor.vertexFunction = library.makeFunction(name: "pointCloudVertex")
        pointDescriptor.fragmentFunction = library.makeFunction(name: "pointCloudFragment")
        pointDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        // Same shaders without a depth buffer, for guide stripes drawn over the camera image.
        let flatDescriptor = pointDescriptor.copy() as! MTLRenderPipelineDescriptor
        pointDescriptor.depthAttachmentPixelFormat = .depth32Float

        let depthStateDescriptor = MTLDepthStencilDescriptor()
        depthStateDescriptor.depthCompareFunction = .less
        depthStateDescriptor.isDepthWriteEnabled = true

        guard let camera = quadPipeline("displayTexture"),
              let depth = quadPipeline("depthColorFragment"),
              let overlay = quadPipeline("overlayFragment"),
              let points = try? device.makeRenderPipelineState(descriptor: pointDescriptor),
              let flatPoints = try? device.makeRenderPipelineState(descriptor: flatDescriptor),
              let guideBuffer = device.makeBuffer(length: 4096 * MemoryLayout<PointCloudVertex>.stride, options: .storageModeShared),
              let depthState = device.makeDepthStencilState(descriptor: depthStateDescriptor) else { return nil }

        self.layer = layer
        self.device = device
        self.commandQueue = commandQueue
        self.quadBuffer = quadBuffer
        self.cameraPipeline = camera
        self.depthPipeline = depth
        self.overlayPipeline = overlay
        self.pointPipeline = points
        self.flatPointPipeline = flatPoints
        self.guideBuffer = guideBuffer
        self.depthStencilState = depthState
        self.textureCache = textureCache
        self.pointCloud = pointCloud
    }

    /// Live preview splat from the PC (ARKit coordinates of this session).
    private var preview: GaussianSplatRenderer?
    func setPreview(_ splats: SplatData?) {
        guard let splats = splats else { preview = nil; return }
        let r = GaussianSplatRenderer(device: device, splats: splats, colorFormat: .bgra8Unorm)
        r?.commandQueue = commandQueue
        preview = r
    }
    var hasPreview: Bool { preview != nil }

    func render(frame: ARFrame) {
        frameNumber += 1
        // Always grow the point cloud so switching to it shows the whole scan so far.
        pointCloud.add(frame: frame)
        uploadGuides()
        let interval = previewInterval * (lowPower ? 2 : 1)
        if frameNumber % max(interval, 1) != 0 { return }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        var keepAlive: [CVMetalTexture] = []
        var drawables: [CAMetalDrawable] = []
        let textures = FrameTextures(frame: frame, renderer: self, keepAlive: &keepAlive)

        if mode == .dim {
            if !clearedForDim, let drawable = layer.nextDrawable() {
                encodeClear(commandBuffer, drawable: drawable)
                drawables.append(drawable)
            }
            clearedForDim = true
        } else {
            clearedForDim = false
            if layer.drawableSize.width > 0, let drawable = layer.nextDrawable() {
                encode(mode: mode, commandBuffer, drawable: drawable, frame: frame, textures: textures,
                       size: layer.drawableSize, isInset: false)
                drawables.append(drawable)
            }
        }

        // Small views refresh at half the preview rate.
        if (frameNumber / max(interval, 1)) % 2 == 0 {
            for inset in insets where inset.mode != .dim {
                if inset.layer.drawableSize.width > 0, let drawable = inset.layer.nextDrawable() {
                    encode(mode: inset.mode, commandBuffer, drawable: drawable, frame: frame, textures: textures,
                           size: inset.layer.drawableSize, isInset: true)
                    drawables.append(drawable)
                }
            }
        }

        for drawable in drawables {
            commandBuffer.present(drawable)
        }
        let retainedTextures = keepAlive
        commandBuffer.addCompletedHandler { _ in
            // Keep the CoreVideo textures alive until the GPU is done with them.
            withExtendedLifetime(retainedTextures) {}
        }
        commandBuffer.commit()
    }

    var metalDevice: MTLDevice { return device }

    func resetPointCloud() {
        pointCloud.reset()
    }

    // MARK: - Passes

    fileprivate struct FrameTextures {
        var y: MTLTexture?
        var cbcr: MTLTexture?
        var depth: MTLTexture?
        var confidence: MTLTexture?

        init(frame: ARFrame, renderer: ScanRenderer, keepAlive: inout [CVMetalTexture]) {
            y = renderer.texture(frame.capturedImage, .r8Unorm, 0, &keepAlive)
            cbcr = renderer.texture(frame.capturedImage, .rg8Unorm, 1, &keepAlive)
            if let sceneDepth = frame.sceneDepth, let confidenceMap = sceneDepth.confidenceMap {
                depth = renderer.texture(sceneDepth.depthMap, .r32Float, 0, &keepAlive)
                confidence = renderer.texture(confidenceMap, .r8Unorm, 0, &keepAlive)
            }
        }
    }

    private func colorPass(_ drawable: CAMetalDrawable, withDepth: Bool) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1.0)
        if withDepth {
            pass.depthAttachment.texture = depthTexture(for: drawable.texture)
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.storeAction = .dontCare
            pass.depthAttachment.clearDepth = 1.0
        }
        return pass
    }

    private func encode(mode: ViewMode, _ commandBuffer: MTLCommandBuffer, drawable: CAMetalDrawable, frame: ARFrame,
                        textures: FrameTextures, size: CGSize, isInset: Bool) {
        switch mode {
        case .camera, .overlay, .depth:
            let pipeline = mode == .camera ? cameraPipeline : (mode == .overlay ? overlayPipeline : depthPipeline)
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: colorPass(drawable, withDepth: false)) else { return }
            encoder.setCullMode(.none)
            if bindQuadTextures(encoder, textures: textures, needsCamera: mode != .depth, needsDepth: mode != .camera) {
                encoder.setRenderPipelineState(pipeline)
                drawQuad(encoder, size: size, image: frame.camera.imageResolution)
            }
            // Path-guide stripes over the live picture.
            if !guideVertices.isEmpty && mode != .depth && !isInset {
                let view = frame.camera.viewMatrix(for: .portrait)
                let projection = frame.camera.projectionMatrix(for: .portrait, viewportSize: size, zNear: 0.02, zFar: 50)
                var uniforms = PointCloudUniforms(viewProjection: projection * view,
                                                  pointScale: Float(size.height) * 0.5 * projection.columns.1.y)
                encoder.setRenderPipelineState(flatPointPipeline)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<PointCloudUniforms>.stride, index: 1)
                drawGuides(encoder)
            }
            encoder.endEncoding()
        case .pointCloud:
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: colorPass(drawable, withDepth: true)) else { return }
            encoder.setCullMode(.none)
            drawPointCloud(encoder, frame: frame, drawableSize: size, chase: isInset ? true : chaseCamera)
            encoder.endEncoding()
        case .map:
            encodeMinimap(commandBuffer, drawable: drawable, frame: frame, size: size)
        case .pcPreview:
            guard let preview = preview else {
                // Nothing from the PC yet: show the camera.
                encode(mode: .camera, commandBuffer, drawable: drawable, frame: frame, textures: textures, size: size, isInset: isInset)
                return
            }
            let pass = colorPass(drawable, withDepth: false)
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1)
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            let view = frame.camera.viewMatrix(for: .portrait)
            let projection = frame.camera.projectionMatrix(for: .portrait, viewportSize: size, zNear: 0.03, zFar: 100)
            preview.draw(encoder, view: view, projection: projection, viewport: size)
            encoder.endEncoding()
        case .dim:
            break
        }
    }

    private func encodeClear(_ commandBuffer: MTLCommandBuffer, drawable: CAMetalDrawable) {
        let pass = colorPass(drawable, withDepth: false)
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
    }

    /// Top-down map centred on the phone, phone heading pointing up, ceiling cut away.
    private func encodeMinimap(_ commandBuffer: MTLCommandBuffer, drawable: CAMetalDrawable, frame: ARFrame, size: CGSize) {
        guard size.width > 0, let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: colorPass(drawable, withDepth: true)) else { return }
        encoder.setCullMode(.none)
        let t = frame.camera.transform
        let position = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let forward = -SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        var flat = SIMD3<Float>(forward.x, 0, forward.z)
        flat = simd_length(flat) > 0.05 ? simd_normalize(flat) : SIMD3<Float>(0, 0, -1)
        let view = ScanRenderer.lookAt(eye: position + SIMD3<Float>(0, 10, 0), target: position, up: flat)
        let halfSize: Float = size.height > 600 ? 5 : 3.5
        let aspect = Float(size.width / max(size.height, 1))
        let projection = ScanRenderer.orthographic(halfWidth: halfSize * aspect, halfHeight: halfSize, near: 0.1, far: 30)
        var uniforms = PointCloudUniforms(viewProjection: projection * view,
                                          pointScale: Float(size.height) * 0.5 * projection.columns.1.y,
                                          clipY: position.y + ceilingCut,
                                          maxPointSize: 8)
        encoder.setRenderPipelineState(pointPipeline)
        encoder.setDepthStencilState(depthStencilState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<PointCloudUniforms>.stride, index: 1)
        drawCloud(encoder)
        drawGuides(encoder)
        drawPhoneMarker(encoder, position: position)
        encoder.endEncoding()
    }

    @discardableResult
    private func bindQuadTextures(_ encoder: MTLRenderCommandEncoder, textures: FrameTextures, needsCamera: Bool, needsDepth: Bool) -> Bool {
        if needsCamera {
            guard let y = textures.y, let cbcr = textures.cbcr else { return false }
            encoder.setFragmentTexture(y, index: 0)
            encoder.setFragmentTexture(cbcr, index: 1)
        }
        if needsDepth {
            guard let depth = textures.depth, let confidence = textures.confidence else { return false }
            encoder.setFragmentTexture(depth, index: 2)
            encoder.setFragmentTexture(confidence, index: 3)
        }
        return true
    }

    // MARK: - Drawing

    private func drawQuad(_ encoder: MTLRenderCommandEncoder, size: CGSize, image: CGSize) {
        encoder.setVertexBuffer(quadBuffer, offset: 0, index: 0)
        // Aspect fill: the sensor image is landscape, shown upright (height/width); widen whichever axis is short.
        let pictureAspect = Float(image.height / max(image.width, 1))
        let viewAspect = Float(size.width / max(size.height, 1))
        var scale = viewAspect < pictureAspect ? SIMD2<Float>(pictureAspect / viewAspect, 1)
                                               : SIMD2<Float>(1, viewAspect / pictureAspect)
        encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private var guideCount = 0

    private func uploadGuides() {
        let count = min(guideVertices.count, guideCapacity)
        if count > 0 {
            let pointer = guideBuffer.contents().bindMemory(to: PointCloudVertex.self, capacity: guideCapacity)
            for i in 0..<count { pointer[i] = guideVertices[i] }
        }
        guideCount = count
    }

    private func drawGuides(_ encoder: MTLRenderCommandEncoder) {
        guard guideCount > 0 else { return }
        encoder.setVertexBuffer(guideBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: guideCount)
    }

    private func drawCloud(_ encoder: MTLRenderCommandEncoder) {
        if showCoverage {
            if pointCloud.coverageCount > 0 {
                encoder.setVertexBuffer(pointCloud.coverageBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: pointCloud.coverageCount)
            }
        } else if pointCloud.count > 0 {
            encoder.setVertexBuffer(pointCloud.buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: pointCloud.count)
        }
    }

    private func drawPhoneMarker(_ encoder: MTLRenderCommandEncoder, position: SIMD3<Float>) {
        var marker = PointCloudVertex(position: SIMD4<Float>(position.x, position.y - 0.05, position.z, 0.25),
                                      color: SIMD4<Float>(1, 1, 1, 1))
        encoder.setVertexBytes(&marker, length: MemoryLayout<PointCloudVertex>.stride, index: 0)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 1)
    }

    private func drawPointCloud(_ encoder: MTLRenderCommandEncoder, frame: ARFrame, drawableSize: CGSize, chase: Bool) {
        let aspect = Float(drawableSize.width / max(drawableSize.height, 1))
        let projection: simd_float4x4
        let view: simd_float4x4
        let t = frame.camera.transform
        let position = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        var clipY = Float.greatestFiniteMagnitude
        if chase {
            let forward = -simd_normalize(SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z))
            var flat = SIMD3<Float>(forward.x, 0, forward.z)
            flat = simd_length(flat) > 0.05 ? simd_normalize(flat) : SIMD3<Float>(0, 0, -1)
            let eye = position - flat * 1.8 + SIMD3<Float>(0, 1.3, 0)
            let target = position + forward * 1.0
            view = ScanRenderer.lookAt(eye: eye, target: target, up: SIMD3<Float>(0, 1, 0))
            projection = ScanRenderer.perspective(fovY: Float(65.0 * Double.pi / 180.0), aspect: aspect, near: 0.05, far: 50)
            // Cut the ceiling away so it doesn't block the overview.
            clipY = position.y + ceilingCut
        } else {
            view = frame.camera.viewMatrix(for: .portrait)
            projection = frame.camera.projectionMatrix(for: .portrait, viewportSize: drawableSize, zNear: 0.02, zFar: 50)
        }
        var uniforms = PointCloudUniforms(viewProjection: projection * view,
                                          pointScale: Float(drawableSize.height) * 0.5 * projection.columns.1.y,
                                          clipY: clipY,
                                          maxPointSize: showCoverage ? 18 : 10)
        encoder.setRenderPipelineState(pointPipeline)
        encoder.setDepthStencilState(depthStencilState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<PointCloudUniforms>.stride, index: 1)
        drawCloud(encoder)
        drawGuides(encoder)
        if chase {
            var marker = PointCloudVertex(position: SIMD4<Float>(position.x, position.y, position.z, 0.08),
                                          color: SIMD4<Float>(1, 1, 1, 1))
            encoder.setVertexBytes(&marker, length: MemoryLayout<PointCloudVertex>.stride, index: 0)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 1)
        }
    }

    private func depthTexture(for target: MTLTexture) -> MTLTexture? {
        let key = (target.width << 16) | target.height
        if let existing = depthAttachments[key] {
            return existing
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                                  width: target.width,
                                                                  height: target.height,
                                                                  mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .private
        let texture = device.makeTexture(descriptor: descriptor)
        depthAttachments[key] = texture
        return texture
    }

    fileprivate func texture(_ pixelBuffer: CVPixelBuffer, _ format: MTLPixelFormat, _ plane: Int,
                         _ keepAlive: inout [CVMetalTexture]) -> MTLTexture? {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        let isPlanar = CVPixelBufferIsPlanar(pixelBuffer)
        let w = isPlanar ? width : CVPixelBufferGetWidth(pixelBuffer)
        let h = isPlanar ? height : CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixelBuffer, nil, format, w, h, plane, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture = cvTexture else { return nil }
        keepAlive.append(cvTexture)
        return CVMetalTextureGetTexture(cvTexture)
    }

    // MARK: - Matrices

    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let z = simd_normalize(eye - target)
        let x = simd_normalize(simd_cross(up, z))
        let y = simd_cross(z, x)
        return simd_float4x4(columns: (
            SIMD4<Float>(x.x, y.x, z.x, 0),
            SIMD4<Float>(x.y, y.y, z.y, 0),
            SIMD4<Float>(x.z, y.z, z.z, 0),
            SIMD4<Float>(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)
        ))
    }

    static func orthographic(halfWidth: Float, halfHeight: Float, near: Float, far: Float) -> simd_float4x4 {
        return simd_float4x4(columns: (
            SIMD4<Float>(1 / halfWidth, 0, 0, 0),
            SIMD4<Float>(0, 1 / halfHeight, 0, 0),
            SIMD4<Float>(0, 0, 1 / (near - far), 0),
            SIMD4<Float>(0, 0, near / (near - far), 1)
        ))
    }

    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let ys = 1 / tan(fovY * 0.5)
        let xs = ys / aspect
        let zs = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4<Float>(xs, 0, 0, 0),
            SIMD4<Float>(0, ys, 0, 0),
            SIMD4<Float>(0, 0, zs, -1),
            SIMD4<Float>(0, 0, zs * near, 0)
        ))
    }
}
