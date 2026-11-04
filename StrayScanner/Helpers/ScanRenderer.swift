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

    static let userDefaultsKey = "ViewMode"

    var title: String {
        switch self {
        case .camera: return "Camera"
        case .depth: return "Depth"
        case .overlay: return "Mix"
        case .pointCloud: return "Points"
        case .dim: return "Dim"
        }
    }

    var symbolName: String {
        switch self {
        case .camera: return "camera.fill"
        case .depth: return "dot.radiowaves.left.and.right"
        case .overlay: return "square.on.square"
        case .pointCloud: return "circle.grid.3x3.fill"
        case .dim: return "moon.fill"
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
    var pad0: Float = 0
    var pad1: Float = 0
    var pad2: Float = 0
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
        let scale = traitCollection.displayScale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }
}

final class ScanRenderer {
    let pointCloud: PointCloudAccumulator
    var mode: ViewMode = .camera
    /// Point cloud seen from behind and above the phone (true) or through the camera (false).
    var chaseCamera: Bool = true

    private let layer: CAMetalLayer
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let quadBuffer: MTLBuffer
    private let cameraPipeline: MTLRenderPipelineState
    private let depthPipeline: MTLRenderPipelineState
    private let overlayPipeline: MTLRenderPipelineState
    private let pointPipeline: MTLRenderPipelineState
    private let depthStencilState: MTLDepthStencilState
    private var depthAttachment: MTLTexture?
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
            descriptor.vertexFunction = library.makeFunction(name: "drawRectangle")
            descriptor.fragmentFunction = library.makeFunction(name: fragmentName)
            descriptor.vertexDescriptor = quadDescriptor
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        let pointDescriptor = MTLRenderPipelineDescriptor()
        pointDescriptor.vertexFunction = library.makeFunction(name: "pointCloudVertex")
        pointDescriptor.fragmentFunction = library.makeFunction(name: "pointCloudFragment")
        pointDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pointDescriptor.depthAttachmentPixelFormat = .depth32Float

        let depthStateDescriptor = MTLDepthStencilDescriptor()
        depthStateDescriptor.depthCompareFunction = .less
        depthStateDescriptor.isDepthWriteEnabled = true

        guard let camera = quadPipeline("displayTexture"),
              let depth = quadPipeline("depthColorFragment"),
              let overlay = quadPipeline("overlayFragment"),
              let points = try? device.makeRenderPipelineState(descriptor: pointDescriptor),
              let depthState = device.makeDepthStencilState(descriptor: depthStateDescriptor) else { return nil }

        self.layer = layer
        self.device = device
        self.commandQueue = commandQueue
        self.quadBuffer = quadBuffer
        self.cameraPipeline = camera
        self.depthPipeline = depth
        self.overlayPipeline = overlay
        self.pointPipeline = points
        self.depthStencilState = depthState
        self.textureCache = textureCache
        self.pointCloud = pointCloud
    }

    func render(frame: ARFrame) {
        // Always grow the point cloud so switching to it shows the whole scan so far.
        pointCloud.add(frame: frame)

        if mode == .dim {
            if !clearedForDim { clear() }
            clearedForDim = true
            return
        }
        clearedForDim = false

        guard layer.drawableSize.width > 0, let drawable = layer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        var keepAlive: [CVMetalTexture] = []

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1.0)

        if mode == .pointCloud {
            pass.depthAttachment.texture = depthTexture(for: drawable.texture)
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.storeAction = .dontCare
            pass.depthAttachment.clearDepth = 1.0
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setCullMode(.none)

        switch mode {
        case .camera:
            if let y = texture(frame.capturedImage, .r8Unorm, 0, &keepAlive),
               let cbcr = texture(frame.capturedImage, .rg8Unorm, 1, &keepAlive) {
                encoder.setRenderPipelineState(cameraPipeline)
                encoder.setFragmentTexture(y, index: 0)
                encoder.setFragmentTexture(cbcr, index: 1)
                drawQuad(encoder)
            }
        case .depth, .overlay:
            if let sceneDepth = frame.sceneDepth, let confidenceMap = sceneDepth.confidenceMap,
               let depth = texture(sceneDepth.depthMap, .r32Float, 0, &keepAlive),
               let confidence = texture(confidenceMap, .r8Unorm, 0, &keepAlive) {
                encoder.setFragmentTexture(depth, index: 2)
                encoder.setFragmentTexture(confidence, index: 3)
                if mode == .overlay,
                   let y = texture(frame.capturedImage, .r8Unorm, 0, &keepAlive),
                   let cbcr = texture(frame.capturedImage, .rg8Unorm, 1, &keepAlive) {
                    encoder.setRenderPipelineState(overlayPipeline)
                    encoder.setFragmentTexture(y, index: 0)
                    encoder.setFragmentTexture(cbcr, index: 1)
                } else {
                    encoder.setRenderPipelineState(depthPipeline)
                }
                drawQuad(encoder)
            }
        case .pointCloud:
            drawPointCloud(encoder, frame: frame, drawableSize: layer.drawableSize)
        case .dim:
            break
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        let retainedTextures = keepAlive
        commandBuffer.addCompletedHandler { _ in
            // Keep the CoreVideo textures alive until the GPU is done with them.
            withExtendedLifetime(retainedTextures) {}
        }
        commandBuffer.commit()
    }

    func resetPointCloud() {
        pointCloud.reset()
    }

    // MARK: - Drawing

    private func drawQuad(_ encoder: MTLRenderCommandEncoder) {
        encoder.setVertexBuffer(quadBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(quadBuffer, offset: 0, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func drawPointCloud(_ encoder: MTLRenderCommandEncoder, frame: ARFrame, drawableSize: CGSize) {
        let aspect = Float(drawableSize.width / max(drawableSize.height, 1))
        let projection: simd_float4x4
        let view: simd_float4x4
        if chaseCamera {
            let t = frame.camera.transform
            let position = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            let forward = -simd_normalize(SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z))
            var flat = SIMD3<Float>(forward.x, 0, forward.z)
            flat = simd_length(flat) > 0.05 ? simd_normalize(flat) : SIMD3<Float>(0, 0, -1)
            let eye = position - flat * 1.6 + SIMD3<Float>(0, 1.1, 0)
            let target = position + forward * 1.0
            view = ScanRenderer.lookAt(eye: eye, target: target, up: SIMD3<Float>(0, 1, 0))
            projection = ScanRenderer.perspective(fovY: Float(65.0 * Double.pi / 180.0), aspect: aspect, near: 0.05, far: 50)
        } else {
            view = frame.camera.viewMatrix(for: .portrait)
            projection = frame.camera.projectionMatrix(for: .portrait, viewportSize: drawableSize, zNear: 0.02, zFar: 50)
        }
        var uniforms = PointCloudUniforms(viewProjection: projection * view,
                                          pointScale: Float(drawableSize.height) * 0.5 * projection.columns.1.y)
        encoder.setRenderPipelineState(pointPipeline)
        encoder.setDepthStencilState(depthStencilState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<PointCloudUniforms>.stride, index: 1)

        if pointCloud.count > 0 {
            encoder.setVertexBuffer(pointCloud.buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: pointCloud.count)
        }
        if chaseCamera {
            // Current phone position as a large white dot.
            let t = frame.camera.transform
            var marker = PointCloudVertex(position: SIMD4<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z, 0.08),
                                          color: SIMD4<Float>(1, 1, 1, 1))
            encoder.setVertexBytes(&marker, length: MemoryLayout<PointCloudVertex>.stride, index: 0)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 1)
        }
    }

    private func clear() {
        guard let drawable = layer.nextDrawable(), let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func depthTexture(for target: MTLTexture) -> MTLTexture? {
        if let existing = depthAttachment, existing.width == target.width, existing.height == target.height {
            return existing
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                                  width: target.width,
                                                                  height: target.height,
                                                                  mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .private
        depthAttachment = device.makeTexture(descriptor: descriptor)
        return depthAttachment
    }

    private func texture(_ pixelBuffer: CVPixelBuffer, _ format: MTLPixelFormat, _ plane: Int,
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
