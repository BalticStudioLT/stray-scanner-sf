# Owner ideas log

Every request/idea from the owner, newest last, so nothing gets lost.

## 2026-11-04
- Fork Stray Scanner for own use with SplatForge: short shutter (Auto / 1/120 / 1/250 / 1/500, default 1/250) with ISO compensation, lock white balance + focus while recording, log real exposure per frame in exposure.csv, keep all existing files identical, free Apple ID signing.

## 2026-11-05
- "Now for the app lets change view to point cloud. Also maybe we can change and improve design? Its old and boring. Make like new iphone liquid glass. And show scan stats. Add recommendations for speed and direction into the app. Make view changeable (camera, lidar, depth, combination of both, function to dim display to save battery) other useful stuff to me and to splatforge."
- (after first test of the new screen, screenshot in Points view) "Could app use multiple cameras at the same time? Specially wide? Maybe even front facing lidar? I would put some mirror and it would extend a view (wild take). Also after i scanned ceiling it obstructed my view. And i would wanna to see better where more scanning is needed. And add a path i could follow. Up and down by every wall 30-80 cm apart. Watching one and another side. Or somehow else to get best scan. And maybe we can integrate tailscale and connection to our computer so it helps us?"
- "And also add option to have small view of camera in a corner, lidar and minimap. As separate items"
- "And check how we can make it so we can continue capture after the crash of phone due to overheating. Show iphone temperature and cpu speed if possible."
- "also button for flash, continuous or every second shot so we could get two different light setups for room."
- 2026-11-05 01:16 "build 4k and tailscale. also other stuff. send leave note for other ai working on splat forge. it will implement it. you later check for its responses (1 hour intervals). you have all night. i am going to sleep. check what else could be useful and possible. optimize app itself so it doesnt draw too much power. think how we can get ultrawide view. maybe separately run it."
- 2026-11-05 01:26 "Flashlight could have lower iso. Because otherwise it will burn out the view. So in beginning there should be calibration"
- 2026-11-05 01:37 [screenshot, Points view with camera+LiDAR+minimap insets, coverage colours] "When everything is on it becomes crowded"
- 2026-11-05 01:39 "Make view more modern, clicking some view swaps it with big screen"
- 2026-11-05 10:10 "maybe 0.5 should be like add more information to scan? after i finished with lidar. also it should capture gyro and all data to help as much as possible with alignment"
- 2026-11-05 10:11 "and connection says wrong studio token"
- 2026-11-05 10:37 (screenshot of scan detail) "After scan layout is wrong. Also i didnt see any help from computer while scanning"
- 2026-11-05 10:39 "And when playing video i would also be able to see all other views."
- 2026-11-05 10:45 "why 0.5 camera didnt had flash? it should use same settings as scan used"
- 2026-11-05 10:46 "and what help is doing computer? because it only says seen"
- 2026-11-05 10:52 (screenshot of splat viewer, kitchen_v2 tiny in the middle) "Also splats loads somewhere very far away"
- 2026-11-05 19:57 (screenshot: dotnuva_tractor hero_30k in viewer, sideways) "I oppened scan on my phone. It stand sideways. Not orientated to ground. Also i would wanna to change quality. Not just to 1m splat."
- 2026-11-05 20:27 "Can we optimize engine?" (splat viewer)
- 2026-11-05 20:51 (screenshot: 4 M splats dotnuva_tractor, smeared/blurry while moving, big blobs near camera) "More moving smedges the splat"
- 2026-11-05 21:01 (2 screenshots: tractor 4M, dark streaks on combine, black sky, blur at bottom) "How else we could improve viewer? I still see black lines behind. Maybe its a question for fiable? Can we use phones gpu?"
- 2026-11-05 21:04 "Its worse" (after log-depth keys + cm² covariance build)
- 2026-11-05 21:09 "Much better. Can we port more of the app to gpu side?" (after full GPU splat sort)
- 2026-11-05 21:11 "And could maybe splatforge optimize view before it has to be done by phone?"
- 2026-11-05 22:27 "Other AI did its job. I want better UI"
- 2026-11-05 22:42 (screenshot of recorder: black gap under preview, insets Depth/Depth/Map, "PC ✓ PC:") "We have a lot of unused soace. And viewer repeats same stuff."
- 2026-11-05 22:53 "I still dont actually understand computer conection. Seems useless"
- 2026-11-05 23:00 "I like 1-2 options." (live PC preview splat while scanning + clear PC tips/verdict)
- 2026-11-05 23:32 (LT) "Mastei kazka apie FSR arba optical flow? Dar niekas nera dares sitam" (FSR/MetalFX upscaling, optical flow — "nobody has done this yet")
- 2026-11-05 23:34 (LT) "Plius galbut galima dar naudoti point of interest quality. Kuomet toliau esantis splat naudoja mazesne rezoliucija o priartejus padideja rezoliucija ir splatu kiekis." (distance-based LOD / streaming detail)
- 2026-11-05 23:39 (LT) "Tinka. Kokiu dar triuku butu galima panaudoti ir sukurti? Gal dlss 5 galima naudoti ar kazka panasaus?" — agreed order: PC preview+tips, optical-flow masks, LOD, MetalFX
- 2026-11-05 23:44 (LT) "Jo man viskas patinka. O del pagrazinimo tai splat net dar tiek arti realaus vaizdo, todel pagrazinimas nepakentu" — all 6 extra tricks approved (variable rasterization, AR occlusion, sky/window/mirror masks, compression, frame reuse, auto tour route); owner OK with AI enhancement since splats are not yet photo-real
- 2026-11-05 23:46 "Search more tricks" — research: RT-Splatting (glass), mirror methods, Structured-Li-GS, PocketGS (on-phone training), Mobile-GS, SOG/SPZ/streamed SOG
- 2026-11-05 23:48 (LT) "Jo pridek viska prie plano ir testavimu" → docs/ROADMAP.md (16 items with tests)
- 2026-11-05 23:50 (LT) "Gal tokios medziagos jau yra mano skenavimuose. Mac turetu but vel prieinamas"
- 2026-11-05 23:51 (LT) "Bet siaip kolkas su langais daug problemu nebuvo. Jie gan gerai gaunasi ant gaussian splatu" → glass item 4 set to low priority
- 2026-11-05 23:51 "its conected" → start item 3 (masks)
- 2026-11-05 23:52 (LT) "Pradek nuo lod, metal fx, ir kitu perfomance patobolinimu" → order changed: LOD, MetalFX, perf first; masks code parked (MotionMaskEncoder.swift, not in the build yet)
- 2026-11-05 23:56 (LT) "Tesk darba"
- 2026-11-05 23:59 "Dont push so often updates. Just finish app" → compile-only on the Mac, one install at the end
- 2026-11-06 00:04 (LT) "Tesk telefono darbus"
- 2026-11-06 00:16 (LT) "Pabandom ta splatu mokyma telefone. Parasyk" → on-phone training (roadmap 16)
- 2026-11-06 00:18 "Do all. I trust you"
- 2026-11-06 00:27 (screenshot: Fastest/sort-free mode with black holes) "Fast mode looks bad. For training talk with splat forge, it knows now a lot of tricks. Also try to optimize it more"
- 2026-11-06 00:28 "And give same information for splat forge, maybe it can it use in dekstop app"
- 2026-11-06 00:32 "Maybe it has some amazing ways on saving memory and processing power to render faster and better" (ask SplatForge)
- 2026-11-06 00:36 (screenshot: viewer shows only sky colour, no splats) "Now i see only sky"
