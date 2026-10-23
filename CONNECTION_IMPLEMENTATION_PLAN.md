# Old iPhone Camera to iPhone Viewer: Implementation Plan

## Decision and first-version scope

Use Swift for both iPhone apps.

- **Camera device:** the existing `iPhoneAsSecureCam` target, running on the iPhone 8.
- **Viewer device:** a new `SecureCamViewer` iOS target in the same Xcode project.
- **First network scope:** both phones are on the same Wi-Fi network.
- **Discovery:** Bonjour through `NWListener` and `NWBrowser`.
- **Video:** H.264 produced and decoded with Apple frameworks.
- **Initial profile:** 1280x720, 10 FPS, approximately 750 Kbit/s, no audio.
- **Viewer limit:** one viewer at a time.
- **Minimum OS:** iOS 16, preserving iPhone 8 support.

Remote viewing over the public internet is not part of this version. Do not expose the camera listener through router port forwarding. A later internet version should use WebRTC or a relay/VPN rather than exposing this protocol directly.

## User experience

### Camera iPhone

1. Launch the camera app and enter Camera Station mode.
2. The phone advertises itself continuously as `iPhone8` while the app remains active.
3. The screen displays availability, viewer status, battery state, thermal state, FPS, and transmitted bitrate.
4. When an authorized viewer connects, capture, encoding, and transmission start automatically.
5. Capture continues while the viewer remains connected.
6. When the viewer intentionally quits, capture and encoding stop and the phone returns to the available state.
7. If the connection disappears unexpectedly, keep the pipeline alive for a five-second reconnection grace period, then stop it.

The camera app cannot programmatically terminate itself. Its local control should therefore be called **Exit Camera Mode**, not Quit. Exiting camera mode stops advertising, closes the viewer connection, stops capture, and returns to the diagnostics screen.

### Viewer iPhone

1. Launch directly into a list of discovered cameras.
2. Tap `iPhone8`.
3. The viewer connects and subscribes automatically; there is no Start button.
4. The live screen stays connected and streaming for as long as it remains open.
5. Temporary network loss triggers automatic reconnection while the live screen is open.
6. Tapping **Quit** disables reconnection, closes the connection, and returns to the camera list.

There is no user-facing Stop button. Internally, stop operations still exist for Quit, app backgrounding, connection failure, camera interruption, and thermal safety.

## Runtime states

### Camera app

```swift
enum CameraServiceState: Equatable {
    case inactive
    case advertising
    case viewerConnecting(name: String)
    case streaming(name: String)
    case reconnectGrace(name: String)
    case thermalPaused
    case failed(message: String)
}
```

State transitions:

```text
inactive
  -> advertising                         enter Camera Station mode
advertising
  -> viewerConnecting                    viewer connects
viewerConnecting
  -> streaming                           handshake and subscription succeed
streaming
  -> advertising                         viewer sends Quit
streaming
  -> reconnectGrace                      connection disappears unexpectedly
reconnectGrace
  -> streaming                           same viewer reconnects within 5 seconds
reconnectGrace
  -> advertising                         grace period expires
any active state
  -> thermalPaused                       thermal safety policy triggers
any state
  -> inactive                            user exits Camera Station mode
```

### Viewer app

```swift
enum ViewerState: Equatable {
    case browsing
    case connecting(cameraID: UUID)
    case live(cameraID: UUID)
    case reconnecting(cameraID: UUID, attempt: Int)
    case failed(cameraID: UUID, message: String)
}
```

Selecting a camera moves directly from `browsing` to `connecting`, then `live`. Quit always returns to `browsing` and must never trigger automatic reconnection.

## Xcode targets and folder layout

Keep the existing target as the camera app. Add one iOS app target named `SecureCamViewer` and one unit-test target named `SecureCamViewerTests`.

Files under `Shared/` must have target membership in both app targets. Camera-only and viewer-only files belong only to their corresponding targets.

```text
iPhoneAsSecureCam/
├── iPhoneAsSecureCam/                         existing camera target
│   ├── iPhoneAsSecureCamApp.swift             modify
│   ├── ContentView.swift                      retain as capability diagnostics
│   ├── UI/
│   │   ├── CameraStationView.swift            add
│   │   └── CameraStationSettingsView.swift    add only when settings are needed
│   ├── Core/
│   │   ├── Camera/
│   │   │   ├── CameraEngine.swift             reuse; small changes only if required
│   │   │   └── VideoFrameCollector.swift      reuse unchanged initially
│   │   ├── Encoding/
│   │   │   ├── H264Encoder.swift              add
│   │   │   └── EncodedVideoFrame.swift        add
│   │   ├── Networking/
│   │   │   ├── CameraAdvertiser.swift         add
│   │   │   └── ViewerConnection.swift         add
│   │   └── Streaming/
│   │       └── LiveStreamCoordinator.swift    add
│   ├── BatteryMonitor.swift                   reuse
│   ├── ThermalMonitor.swift                   reuse
│   ├── TelemetryModels.swift                  modify
│   └── CapabilityTestController.swift         modify after streaming works
│
├── Shared/                                    add; membership in both app targets
│   ├── Protocol/
│   │   ├── SecureCamMessage.swift             add
│   │   ├── SecureCamPacket.swift              add
│   │   └── PacketStreamDecoder.swift          add
│   ├── Models/
│   │   ├── CameraDescriptor.swift             add
│   │   └── StreamConfiguration.swift          add
│   └── Networking/
│       └── SecureCamService.swift             add
│
├── SecureCamViewer/                           new viewer target
│   ├── SecureCamViewerApp.swift               add
│   ├── Models/
│   │   └── ViewerState.swift                  add
│   ├── Discovery/
│   │   └── CameraBrowser.swift                add
│   ├── Networking/
│   │   └── CameraClient.swift                 add
│   ├── Playback/
│   │   ├── H264Decoder.swift                  add
│   │   └── VideoDisplayView.swift             add
│   └── UI/
│       ├── CameraListView.swift               add
│       └── LiveCameraView.swift               add
│
├── iPhoneAsSecureCamTests/
│   ├── PacketStreamDecoderTests.swift         add
│   ├── H264EncoderTests.swift                 add where practical
│   └── LiveStreamCoordinatorTests.swift       add
│
└── SecureCamViewerTests/
    ├── CameraBrowserTests.swift               add with injected browser events
    └── CameraClientTests.swift                add with an in-memory transport
```

Do not move the existing top-level files merely to match this tree. Move a file only when its implementation is already being changed.

## Existing files to modify

### `iPhoneAsSecureCamApp.swift`

- Make Camera Station the main product screen.
- Provide a navigation link to the existing capability diagnostics.
- Do not automatically start capture at app launch; start only the low-cost listener and Bonjour advertisement.

### `CameraEngine.swift`

- Continue using its single `AVCaptureSession`.
- Reuse `addFrameHandler` to feed sample buffers to `H264Encoder`.
- Do not add networking or viewer state to this class.
- Preserve camera interruption events and the serial session queue.

### `TelemetryModels.swift`

Add fields for:

- Encoded frames and keyframes.
- Encoded bytes and transmitted bytes.
- Current encoded bitrate.
- Viewer connection state.
- Connection attempts and disconnect reason.
- Encode duration and end-to-end frame latency when available.

### `CapabilityTestController.swift`

Do not change this until the first phone-to-phone stream works. Then add one `Streaming 720p / 10 FPS` scenario that uses the production encoder and transport so capability measurements represent the real workload.

### Xcode project settings

Modify target settings rather than maintaining a handwritten Info.plist:

- Add the `SecureCamViewer` and `SecureCamViewerTests` targets.
- Add `NSLocalNetworkUsageDescription` to both apps.
- Add `_securecam._tcp` under `NSBonjourServices` in both apps.
- Add camera permission only to the camera target.
- Set both app deployment targets to iOS 16.

## New camera-app files

### `Core/Encoding/EncodedVideoFrame.swift`

Define the encoder output without networking knowledge:

```swift
struct EncodedVideoFrame: Sendable {
    let presentationTimeMicroseconds: UInt64
    let durationMicroseconds: UInt32
    let isKeyFrame: Bool
    let data: Data
    let format: H264Format?
}
```

`H264Format` contains width, height, and SPS/PPS parameter sets. Include it on the first frame and whenever the format changes.

### `Core/Encoding/H264Encoder.swift`

Responsibilities:

- Own one `VTCompressionSession` on a dedicated serial queue.
- Configure real-time H.264 with frame reordering disabled.
- Begin at 1280x720, 10 FPS, approximately 750 Kbit/s.
- Request a keyframe at least every two seconds.
- Accept `CMSampleBuffer` values from `CameraEngine`.
- Emit `EncodedVideoFrame` values.
- Record encoded frames, keyframes, bytes, failures, and encode duration.
- Stop and invalidate its compression session when streaming ends.

The encoder must not own the camera or network connection.

### `Core/Networking/CameraAdvertiser.swift`

Responsibilities:

- Create an `NWListener` on TCP.
- Advertise `_securecam._tcp` through Bonjour.
- Put the stable camera UUID, display name, and protocol version in the Bonjour metadata.
- Accept only one active viewer in version 1.
- Reject additional viewers with a `cameraBusy` error.
- Hand accepted connections to `LiveStreamCoordinator`.

Advertising remains active while Camera Station mode is active, whether or not the camera is capturing.

### `Core/Networking/ViewerConnection.swift`

Responsibilities:

- Wrap one accepted `NWConnection`.
- Decode inbound packets using `PacketStreamDecoder`.
- Send control, video, heartbeat, and telemetry packets.
- Serialize sends so frame bytes cannot interleave.
- Track queued bytes and apply backpressure.
- When the viewer falls behind, drop non-keyframes instead of allowing an unlimited queue.
- Report intentional Quit separately from an unexpected disconnect.

### `Core/Streaming/LiveStreamCoordinator.swift`

This is the only object that coordinates camera, encoder, and connection lifetimes.

Responsibilities:

- Own `CameraServiceState`.
- Start `CameraEngine` and `H264Encoder` after a viewer completes the handshake and automatically subscribes.
- Route captured frames into the encoder.
- Route encoded frames into `ViewerConnection`.
- Keep streaming until Quit, unrecoverable failure, app backgrounding, or thermal safety intervention.
- Stop immediately on intentional Quit.
- Apply the five-second grace period on an unexpected disconnect.
- Keep the network connection alive but pause video if the device enters the configured thermal-pause state.
- Never manipulate SwiftUI views directly.

### `UI/CameraStationView.swift`

Display:

- Camera name: `iPhone8` by default, editable when not streaming.
- `Available`, `Connecting`, `Live`, `Reconnecting`, `Thermal paused`, or `Error` status.
- Connected viewer name.
- Battery percentage and charging state.
- Thermal state.
- Captured FPS, encoded FPS, transmitted bitrate, and dropped frames.
- **Exit Camera Mode** button.

Do not add Start or Stop buttons.

## Shared protocol files

### `Shared/Networking/SecureCamService.swift`

Define shared constants:

```swift
enum SecureCamService {
    static let bonjourType = "_securecam._tcp"
    static let protocolVersion: UInt8 = 1
    static let maximumPayloadBytes = 1_048_576
}
```

### `Shared/Models/CameraDescriptor.swift`

```swift
struct CameraDescriptor: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let endpoint: NWEndpoint
    let protocolVersion: UInt8
}
```

If `NWEndpoint` makes value equality awkward, keep the endpoint in an app-owned wrapper rather than weakening equality throughout the UI.

### `Shared/Models/StreamConfiguration.swift`

Define the agreed stream properties:

- Codec: H.264.
- Width and height.
- FPS.
- Timescale.
- SPS and PPS parameter sets.

### `Shared/Protocol/SecureCamMessage.swift`

Version 1 message types:

| Message | Direction | Purpose |
|---|---|---|
| `hello` | both | Protocol version, device ID, and display name |
| `subscribe` | viewer to camera | Automatically sent after selection; requests the default profile |
| `streamConfiguration` | camera to viewer | Width, height, timescale, SPS, and PPS |
| `videoFrame` | camera to viewer | One encoded H.264 access unit |
| `telemetry` | camera to viewer | Battery, thermal state, FPS, bitrate, and drops |
| `heartbeat` / `heartbeatReply` | both | Detect dead connections |
| `goodbye` | viewer to camera | Intentional Quit; prevents reconnection grace behavior |
| `error` | both | Version mismatch, busy camera, invalid packet, or stream failure |

Control payloads use `Codable` JSON. Video payloads remain binary.

### `Shared/Protocol/SecureCamPacket.swift`

Every TCP packet uses a fixed binary header followed by a payload:

```text
4 bytes  magic value "SCAM"
1 byte   protocol version
1 byte   message type
2 bytes  flags
4 bytes  payload length, unsigned and network byte order
8 bytes  presentation timestamp in microseconds
N bytes  payload
```

Reject packets with the wrong magic/version or payloads larger than `maximumPayloadBytes` before allocating memory for them.

### `Shared/Protocol/PacketStreamDecoder.swift`

TCP does not preserve application-message boundaries. This file must:

- Buffer incomplete data.
- Emit zero or more complete packets for every received chunk.
- Handle a header split across receives.
- Handle a payload split across receives.
- Handle several packets combined in one receive.
- Reject malformed or oversized packets and close the connection.

This component receives unit tests before networking is connected to video.

## New viewer-app files

### `Discovery/CameraBrowser.swift`

Responsibilities:

- Browse for `_securecam._tcp` using `NWBrowser`.
- Convert results into stable `CameraDescriptor` values.
- Update the device list when cameras appear, disappear, or change names.
- Never initiate a connection by itself.

### `Networking/CameraClient.swift`

Responsibilities:

- Connect to the selected descriptor with `NWConnection`.
- Complete the version handshake.
- Automatically send `subscribe`; no UI Start action exists.
- Decode stream packets and forward configuration/video to playback.
- Send heartbeats and detect timeouts.
- Retry after 1, 2, and 4 seconds, then every 5 seconds while `LiveCameraView` remains open.
- Stop retrying immediately when the user taps Quit.

### `Playback/H264Decoder.swift`

Responsibilities:

- Create a `CMVideoFormatDescription` from received SPS/PPS data.
- Own and update a `VTDecompressionSession`.
- Decode access units on a dedicated queue.
- Emit decoded `CVPixelBuffer` values with timestamps.
- Reset on a new stream configuration or decode failure.
- Discard frames until the next keyframe after data loss.

### `Playback/VideoDisplayView.swift`

- Wrap the smallest UIKit/Core Animation view needed to display decoded pixel buffers.
- Use `AVSampleBufferDisplayLayer` for presentation.
- Preserve aspect ratio and use a black background.
- Do not contain connection or decoder logic.

### `UI/CameraListView.swift`

- Display discovered cameras by name and availability.
- Show an empty state when none are present.
- Tapping `iPhone8` creates the client and navigates immediately to `LiveCameraView`.

### `UI/LiveCameraView.swift`

- Display the video surface.
- Show Connecting/Reconnecting/Thermal paused overlays without leaving the screen.
- Show low-rate battery, thermal, FPS, and bitrate information.
- Provide one **Quit** button.
- Quit sets an intentional-exit flag before closing the connection, preventing automatic reconnection.
- Do not provide Start or Stop controls.

## Connection and streaming sequence

```text
Camera app                                  Viewer app
----------                                  ----------
Advertise _securecam._tcp
                                            Browse and show "iPhone8"
                                            User taps "iPhone8"
                 <-------------------------- TCP connection
hello            -------------------------->
                 <-------------------------- hello
                 <-------------------------- subscribe(default 720p/10)
Start camera
Start encoder
streamConfiguration ----------------------->
videoFrame        --------------------------> decode and display
telemetry         --------------------------> update overlay
heartbeat         <------------------------> heartbeatReply
                 <-------------------------- goodbye (Quit)
Stop encoder
Stop camera
Return to advertising                       Return to camera list
```

## Safety and lifecycle rules

- The iPhone 8 camera app must remain foregrounded; normal iOS camera capture cannot be relied on after backgrounding.
- Set `UIApplication.shared.isIdleTimerDisabled = true` only while Camera Station mode is active.
- Backgrounding either app closes its active streaming connection.
- An intentional Quit stops immediately and does not reconnect.
- An unexpected disconnect allows a five-second grace period.
- `critical` thermal state stops camera and encoding immediately.
- Sustained `serious` thermal state pauses the stream according to the existing safety policy and sends a status message to the viewer.
- The viewer must display thermal pause as unavailable video, never as a frozen live image.
- Audio, recording, motion detection, notifications, and cloud upload remain off in this phase.

## Security milestones

The first packet-framing and video milestone may run only on a trusted development Wi-Fi network. It is not ready for deployment merely because the video appears.

Before unattended use:

1. Add explicit first-time pairing between the camera and viewer.
2. Store the paired viewer identity in the Keychain.
3. Require authenticated encrypted transport.
4. Reject unpaired viewers before starting the camera.
5. Add a camera-side action to forget the paired viewer.
6. Test replay, malformed packet, oversized payload, and unauthorized connection behavior.

Do not invent custom cryptography. Use an Apple-supported TLS configuration or replace the transport with WebRTC if secure transport becomes larger than this local protocol warrants.

## Implementation milestones

### Milestone 1: shared framing without video

Add:

- `SecureCamService.swift`
- `SecureCamMessage.swift`
- `SecureCamPacket.swift`
- `PacketStreamDecoder.swift`
- Packet decoder unit tests

Verify:

- Fragmented and combined TCP data decode correctly.
- Invalid versions and payload sizes are rejected.
- Both app targets compile the same shared protocol types.

### Milestone 2: discovery and automatic connection

Add:

- Viewer target and app shell.
- `CameraAdvertiser.swift`
- `CameraBrowser.swift`
- `CameraClient.swift` with hello, subscribe, heartbeat, goodbye, and error messages only.
- `CameraListView.swift` and placeholder `LiveCameraView.swift`.

Verify:

- `iPhone8` appears and disappears from the viewer list.
- Tapping it connects without a Start button.
- Quit returns to the list without reconnecting.
- Unexpected Wi-Fi interruption does attempt reconnection.
- A second viewer receives `cameraBusy`.

### Milestone 3: H.264 encoding on the camera

Add:

- `EncodedVideoFrame.swift`
- `H264Encoder.swift`
- Encoder metrics

Verify locally before transmission:

- 720p/10 FPS encodes near the requested bitrate.
- Keyframes appear at least every two seconds.
- SPS/PPS are available before the first decodable frame.
- Camera and encoder stop after intentional Quit.

### Milestone 4: transmit, decode, and display

Add:

- Video packet sending and backpressure in `ViewerConnection.swift`.
- `H264Decoder.swift`.
- `VideoDisplayView.swift`.
- Real `LiveCameraView.swift`.

Verify:

- Selecting `iPhone8` produces live video automatically.
- Video remains live for at least 30 minutes.
- Quit stops video and camera capture.
- Viewer reconnects after an accidental interruption.
- Memory and queued bytes remain bounded when Wi-Fi is degraded.

### Milestone 5: production telemetry and capability test

Modify:

- `TelemetryModels.swift`
- `CapabilityTestController.swift`
- `CameraStationView.swift`
- Viewer overlay

Verify:

- Camera and viewer frame counts can be compared.
- Bitrate, disconnects, reconnect duration, and latency are logged.
- Run the existing unplugged and powered thermal tests using the real stream.

### Milestone 6: pairing and encrypted transport

Add the smallest Apple-supported authentication and TLS design that satisfies the security milestones. Keep its files under `Shared/Security/`, with separate Keychain stores for each target.

Verify before unattended use:

- An unpaired viewer cannot subscribe.
- Captured network traffic does not reveal video or credentials.
- Reinstalling or forgetting a peer requires pairing again.
- Invalid authentication never starts the camera pipeline.

## Definition of done for the local live-view version

- Both apps run on physical iPhones using iOS 16 or later.
- The viewer discovers `iPhone8` on the same Wi-Fi network.
- Selecting it begins live 720p/10 FPS video without a Start button.
- The stream remains active while the live screen is open.
- Quit disconnects, stops the camera workload, returns to the list, and does not reconnect.
- Unexpected connection loss reconnects automatically while the live screen remains open.
- Thermal safety can pause or end the stream and explains the state on both devices.
- A 30-minute run has bounded memory, bounded send queues, acceptable latency, and no unexplained disconnects.
- The protocol rejects malformed and oversized packets.
- Pairing and encryption are complete before the system is considered safe for unattended use.

