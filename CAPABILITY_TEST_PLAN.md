# iPhone 8 Camera Capability Test Plan

## Purpose

Before building a complete security-camera product, measure whether this particular iPhone 8 can operate safely and reliably in three modes:

1. **On-demand live view:** the camera and encoder run only while a viewer is connected.
2. **Continuous camera:** capture, encoding, and transmission run continuously.
3. **Snapshot hybrid:** the phone takes and compares periodic snapshots while idle, then switches to live video when a viewer connects.

The tests must answer:

- What is the aged battery's practical health and usable runtime?
- How quickly does the phone charge with the selected adapter?
- Can the charger power each workload without the battery slowly discharging?
- Does each workload reach a safe, stable thermal state?
- Can the camera, encoder, and network operate reliably for hours or days?
- What wall-power consumption and annual energy use should be expected?

## Important measurement limits

Public iOS APIs can report:

- Battery percentage and whether the device is charging.
- A categorical thermal state: `nominal`, `fair`, `serious`, or `critical`.
- Captured, encoded, transmitted, and dropped-frame counts.
- Encoding, snapshot, comparison, connection, and reconnection durations.
- Bytes transmitted, app lifecycle events, and camera interruptions.

Public iOS APIs do **not** report:

- Exact battery temperature.
- Instantaneous charging voltage, current, or wattage.
- Battery cycle count.
- Battery maximum capacity or internal resistance.
- Accurate system-wide power consumption.

Use external/manual measurements for the missing data:

- Record **Settings > Battery > Battery Health > Maximum Capacity** and the Peak Performance Capability message.
- Use an inline USB power meter for volts, amps, watts, and accumulated watt-hours.
- Use a room thermometer for ambient temperature.
- Use an infrared thermometer or contact probe at a marked, repeatable point on the rear case.

Do not derive instantaneous watts from changes in `UIDevice.batteryLevel`; the battery percentage is too coarse.

## Test software

Build two programs and avoid third-party dependencies during capability testing.

### 1. `CameraCapabilityLab` iPhone app

The iPhone app runs controlled workloads and records telemetry.

| Component | Framework and classes | Purpose |
|---|---|---|
| `CapabilityTestController` | Foundation, Swift concurrency | Starts test runs, manages warm-up and measurement periods, records operator inputs, and performs safety stops |
| `ScenarioDefinition` | `Codable` | Stores duration, resolution, FPS, bitrate, charger ID, snapshot interval, and network behavior |
| `BatteryMonitor` | UIKit: `UIDevice.current` | Records `batteryLevel`, `batteryState`, and battery-change notifications |
| `ThermalMonitor` | Foundation: `ProcessInfo.thermalState` | Records the current thermal category and state-change notifications |
| `CameraEngine` | AVFoundation: `AVCaptureSession`, `AVCaptureDevice`, `AVCaptureDeviceInput` | Owns and configures the single physical-camera session used by every mode |
| `VideoFrameCollector` | `AVCaptureVideoDataOutput`, `AVCaptureVideoDataOutputSampleBufferDelegate` | Receives pixel buffers and records delivered and dropped frames |
| `PhotoCaptureWorkload` | `AVCapturePhotoOutput`, `AVCapturePhotoCaptureDelegate` | Performs cold-start snapshots and records capture duration |
| `H264Encoder` | VideoToolbox: `VTCompressionSession` | Produces a realistic hardware H.264 encoding workload |
| `ConnectionController` | Network: `NWListener`, `NWConnection`, `NWPathMonitor` | Accepts viewer commands and sends encoded data or telemetry |
| `SceneBrightnessAnalyzer` | CoreVideo plus Accelerate or Core Image; `AVCaptureDevice.iso`, `exposureDuration` | Classifies the scene as daylight, dim, or dark/blind |
| `FrameChangeDetector` | CoreVideo plus Accelerate; Vision feature prints only when needed | Computes an inexpensive change score and decides whether more expensive analysis is justified |
| `PersonDetector` | Vision: `VNDetectHumanRectanglesRequest`, `VNImageRequestHandler` | Detects likely people in selected snapshots or throttled video frames |
| `ModeCoordinator` | Foundation, Swift concurrency | Moves the shared camera pipeline between standby, snapshot, live, continuous, and thermal-paused states |
| `TelemetryRecorder` | Foundation: `FileManager`, `JSONEncoder` or CSV | Stores samples and events locally for later export |
| `RunInterface` | SwiftUI or UIKit | Selects a scenario and displays its state, timer, telemetry, and stop control |

The run interface should graph the recent in-memory samples while the complete data remains in the exported telemetry file:

- Battery percentage over elapsed time, with an estimated percentage-point-per-hour slope after enough samples exist.
- The categorical thermal state as a step graph (`nominal` through `critical`).
- Delivered camera FPS for camera scenarios, alongside cumulative captured and dropped-frame counts.

Call the battery graph **Battery & charging trend**, not charging efficiency. True electrical efficiency requires synchronized USB-meter input power or watt-hours plus a defensible estimate of energy stored in the aged battery; iOS battery percentage alone cannot provide it.

Use the `NWListener` and `NWConnection` APIs supported by iOS 16 rather than newer networking types that require later systems.

### Shared camera and analysis modules

The three product modes should use one camera pipeline rather than three separate implementations. `CapabilityTestController` remains responsible for the lifetime of a measured test run. `ModeCoordinator` is a separate object responsible for changing the camera workload within that run. Keeping those responsibilities separate prevents test logging and camera state transitions from becoming one large controller.

#### `CameraEngine`

File: `Core/Camera/CameraEngine.swift`

Responsibilities:

- Own the app's only `AVCaptureSession` and its dedicated serial session queue.
- Select the rear wide-angle camera and apply the scenario's resolution and FPS.
- Add `AVCaptureVideoDataOutput` for live frames and `AVCapturePhotoOutput` for snapshots.
- Start and stop capture only when requested by `ModeCoordinator`.
- Publish frames to analysis and encoding consumers without knowing which product mode requested them.
- Report capture start latency, delivered frames, dropped frames, interruptions, and errors to telemetry.
- Expose current ISO and exposure duration so brightness classification can distinguish a merely dark image from one produced with a long, noisy exposure.

The engine should not perform person detection, network transmission, or mode decisions. Those are separate consumers of its output.

#### `SceneBrightnessAnalyzer`

File: `Core/Analysis/SceneBrightnessAnalyzer.swift`

Input: a downsampled luminance plane from a `CVPixelBuffer`, plus current ISO and exposure duration.

Output: a small value type containing average luminance and a state such as `daylight`, `dim`, or `darkBlind`.

Responsibilities:

- Downsample the frame before analysis so brightness measurement remains inexpensive.
- Calculate mean luminance using Accelerate/vImage or a small Core Image reduction.
- Smooth measurements across several samples.
- Use different enter and exit thresholds so the classification does not rapidly alternate near a boundary.
- Mark a truly unusable frame as `darkBlind`. In that state, "no person detected" must not be treated as proof that the room is empty.

Time of day may be stored as metadata or used to choose a reference bucket, but it must not decide whether the camera can currently see.

#### `FrameChangeDetector`

File: `Core/Analysis/FrameChangeDetector.swift`

Input: the current downsampled grayscale frame and the appropriate previous/reference frame.

Output: a normalized change score and a Boolean indicating whether to run person detection.

Responsibilities:

- Compute a low-cost difference, initially mean absolute pixel difference on small grayscale images.
- Ignore minor sensor noise using an experimentally chosen threshold.
- Maintain separate reference buckets for daylight and dim scenes so a lighting transition is not automatically treated as a person.
- Skip comparison and report `insufficientVisibility` when the brightness analyzer reports `darkBlind`.
- Record comparison duration and score in telemetry.

Vision feature prints can be benchmarked as a second implementation, but a small pixel-difference gate should be the first capability-test implementation because it is easier to interpret and cheaper to run.

#### `PersonDetector`

File: `Core/Analysis/PersonDetector.swift`

Input: only snapshots or frames selected by `FrameChangeDetector`.

Output: Vision observations converted into app-owned results containing confidence and normalized bounding rectangles.

Responsibilities:

- Run `VNDetectHumanRectanglesRequest` with `VNImageRequestHandler` off the main thread.
- Limit analysis to a measured rate, initially one frame per second for live testing rather than every captured frame.
- Return `notEvaluated` when visibility is insufficient; do not return a false "empty room" result.
- Record analysis duration, number of observations, and confidence values in telemetry.

Person detection is an alerting aid, not proof of presence or absence. Test its false positives and missed detections at several distances and lighting levels on the actual mounted iPhone.

#### `ModeCoordinator`

File: `Core/Modes/ModeCoordinator.swift`

The initial state model should remain small:

```swift
enum CameraModeState {
    case standby
    case capturingSnapshot
    case analyzingSnapshot
    case liveOnDemand
    case continuous
    case thermalPaused
}
```

Responsibilities:

- Be the single place that decides when the camera, encoder, audio input, and transport start or stop.
- Reuse the same live pipeline for on-demand and continuous modes.
- Perform the snapshot sequence: start camera, wait for exposure to settle, capture, analyze, and stop camera.
- Cancel pending work cleanly when a viewer connects or a test stops.
- Move to `thermalPaused` when the safety policy requires it and record every transition.
- Never manipulate SwiftUI views directly; expose observable state that the interface can display.

The intended flow is:

```text
ModeCoordinator
    -> CameraEngine
        -> Video frames -> SceneBrightnessAnalyzer
                        -> FrameChangeDetector
                        -> PersonDetector (only when gated in)
        -> H264Encoder -> ConnectionController
        -> Photo capture -> snapshot/reference storage
    -> TelemetryRecorder
```

### Mode reuse and audio policy

| State | Camera | Encoder/video transport | Image analysis | Audio |
|---|---|---|---|---|
| On-demand standby | Off | Listener only | Off | Off |
| On-demand viewer connected | On | On | Optional/throttled | Optional |
| Continuous | On | On | Throttled | Off for initial energy tests |
| Snapshot idle | On only around each capture | Off except for reports | Brightness, change, then person | Off |
| Snapshot with viewer connected | Same as on-demand live | On | Optional/throttled | Optional |
| Thermal paused | Off | Status only | Off | Off |

Live modes can later share one `MediaTransport` for video, audio, viewer commands, and low-rate telemetry. Audio capture should be its own optional source and should remain off in standby and snapshot operation. Excluding audio from the first camera comparison keeps the power results attributable to the camera, analysis, encoding, and network stages.

### Proposed Xcode folder layout

Use physical folders under `iPhoneAsSecureCam/iPhoneAsSecureCam/`. The current Xcode project uses a filesystem-synchronized root group, so new files and folders placed there should appear in the project navigator without manually editing `project.pbxproj`.

```text
iPhoneAsSecureCam/iPhoneAsSecureCam/
├── App/
│   └── iPhoneAsSecureCamApp.swift
├── UI/
│   ├── ContentView.swift
│   ├── Components/
│   │   └── MetricCard.swift                 (when extracted from ContentView)
│   └── ShareSheet.swift
├── Core/
│   ├── Camera/
│   │   ├── CameraEngine.swift
│   │   ├── VideoFrameCollector.swift
│   │   └── PhotoCaptureWorkload.swift
│   ├── Analysis/
│   │   ├── SceneBrightnessAnalyzer.swift
│   │   ├── FrameChangeDetector.swift
│   │   └── PersonDetector.swift
│   ├── Modes/
│   │   ├── CameraMode.swift
│   │   └── ModeCoordinator.swift
│   ├── Encoding/
│   │   └── H264Encoder.swift
│   ├── Networking/
│   │   └── ConnectionController.swift
│   └── Telemetry/
│       ├── BatteryMonitor.swift
│       ├── ThermalMonitor.swift
│       ├── TelemetryModels.swift
│       └── TelemetryRecorder.swift
└── Testing/
    └── CapabilityTestController.swift
```

This is a frontend/core separation, not a frontend/backend separation:

- `UI` contains SwiftUI views and presentation-only helpers.
- `Core` contains camera, analysis, encoding, networking, and telemetry code that should not depend on SwiftUI.
- `Testing` coordinates the capability experiment and provides observable results to the UI.
- A future `CameraLoadReceiver` Mac target or cloud service is the actual backend and should live in a separate target or project rather than inside the iPhone app's `Core` folder.

Do not move all existing files merely to create this layout before the new modules are implemented. Introduce the folders as each component is added, then move an existing file only when a code change already requires touching it. This keeps restructuring separate from behavioral changes.

### Minimal implementation and test order

Implement only enough shared behavior to answer one capability question at a time:

1. Add `CameraEngine` and a manual camera-on scenario. Verify preview/capture counters, FPS, battery slope, and thermal logging.
2. Add `SceneBrightnessAnalyzer`. Verify daylight, normal indoor, dim, and lights-off samples; lights-off should become `darkBlind`.
3. Add `FrameChangeDetector`. Verify unchanged empty-room frames stay below the threshold and a walking person produces a higher score.
4. Add `PersonDetector` behind the change gate. Measure detection time and accuracy at approximately 1, 3, and 5 metres in each usable lighting condition.
5. Add `ModeCoordinator` and expose a temporary UI selector for the three workload modes. Verify from telemetry that each state starts and stops only the components shown in the mode table.
6. Add encoding and network transport after the local camera and analysis costs are understood. Add audio last as a separate comparison run.

This sequence is deliberate development while testing: each new component creates a measurable workload, but it avoids building three complete products before learning whether the iPhone 8 can sustain them.

### 2. `CameraLoadReceiver` Mac app

The receiver creates a real network workload and observes delivery from the Mac side.

It should:

- Discover the phone through Bonjour with `NWBrowser`.
- Connect with `NWConnection`.
- Send `START_LIVE`, `STOP_LIVE`, and configuration commands.
- Receive encoded frames or framed test data.
- Count received bytes, frames, gaps, disconnects, and reconnection time.
- Optionally decode H.264 using `VTDecompressionSession`.
- Receive a low-rate telemetry stream and write a Mac-side CSV.

A polished video player is not required for the initial capability test.

## Suggested telemetry format

Record one sample every 10 seconds. Also record immediate event rows for thermal changes, power-state changes, camera interruptions, connection changes, and errors.

```swift
struct TelemetrySample: Codable {
    let runID: UUID
    let scenarioID: String
    let timestamp: Date
    let elapsedSeconds: Double

    let batteryLevel: Float
    let batteryState: String
    let thermalState: String

    let capturedFrames: Int
    let droppedFrames: Int
    let encodedFrames: Int
    let transmittedBytes: Int64

    let cameraRunning: Bool
    let encoderRunning: Bool
    let viewerConnected: Bool

    let lastEncodeMilliseconds: Double?
    let lastSnapshotMilliseconds: Double?
    let lastComparisonMilliseconds: Double?
}
```

Every run should also contain metadata recorded at its start:

- App version and build number.
- iOS version.
- Scenario configuration.
- Adapter and cable identifiers.
- Starting battery percentage.
- Battery maximum-capacity percentage entered manually.
- Ambient and initial rear-case temperatures entered manually.
- Screen brightness and network configuration.

Store logs under `Application Support/TestRuns/<run-id>/` and provide an Export button using a share sheet. Keep a local copy even when live telemetry is being sent to the Mac so a network failure does not destroy the test record.

## Workload definitions

### Mode A: on-demand live view

While no viewer is connected:

- Keep the app in the foreground with a nearly black interface.
- Keep only the network listener and telemetry recorder active.
- Stop `AVCaptureSession`.
- Invalidate or idle the H.264 encoder.

When a viewer connects:

- Start capture.
- Start H.264 encoding.
- Transmit video to the receiver.
- Stop capture and encoding after the viewer disconnects.

Measure standby consumption, active consumption, start latency, stop latency, reconnection behavior, and temperature in both states.

### Mode B: continuous camera

- Keep camera capture, H.264 encoding, and transmission active.
- Begin with 720p at 10 or 15 FPS and no audio.
- Run a four-hour test before attempting a 24-hour soak.

The active portion of Mode A and Mode B use essentially the same workload. Mode B primarily adds long-duration thermal and reliability requirements.

### Mode C: snapshot hybrid

When no viewer is connected:

1. Start the camera session.
2. Wait briefly for exposure and white balance to settle.
3. Capture one image.
4. Generate an image feature print.
5. Compare it with a small matching reference set.
6. Stop and release the camera session.

When a viewer connects, switch to Mode A's live state.

For meaningful power savings, stop `AVCaptureSession` between snapshots. A separate control test should leave the session running while saving only one snapshot every five minutes. Comparing the two demonstrates how much energy is saved by cold capture rather than merely discarding unwanted frames.

For the representative comparison workload, use:

- `VNImageRequestHandler`
- `VNGenerateImageFeaturePrintRequest`
- `VNFeaturePrintObservation.computeDistance`

For capability testing, four daytime and four nighttime references are enough to represent the likely CPU/Neural Engine work. Accurate anomaly classification is a later project.

## Controlled setup

Keep the following constant between runs:

- Remove the phone case.
- Use the same open mount and phone orientation.
- Use the same known-good Lightning cable.
- Use the same Wi-Fi access point and phone location.
- Disable cellular if cellular will not be part of the product.
- Manually disable auto-brightness and use the same low brightness.
- Avoid direct sunlight and insulating surfaces.
- Prefer an ambient temperature around 20-22 degrees Celsius.
- Allow the phone to return close to its starting temperature before another run.
- Install a Release build and disconnect Xcode before formal measurements.

Apple documents an operating ambient range of 0-35 degrees Celsius and says 16-22 degrees Celsius is ideal for battery longevity. Camera use, streaming, and charging can all add heat.

## Test sequence

### Phase 0: physical and battery-health gate

Before long tests:

- Inspect for screen lifting, battery swelling, odor, enclosure deformation, or a damaged connector.
- Record Maximum Capacity from Battery Health.
- Record the Peak Performance Capability message.
- Record any history of unexpected shutdowns.
- Check available storage.
- Verify that the Lightning connector maintains a stable connection.

Stop testing if the battery is swollen or lifting the display.

### Phase 1: charger characterization

Use the selected Apple 30 W dual-port adapter and the same known-good Apple cable for every powered run. Leave the adapter's other port empty because connecting another device can change how power is shared. Record the exact adapter model and port used. Do not use wireless charging for these tests.

For the adapter:

1. Bring the battery to approximately 20%.
2. Let the phone return close to room temperature.
3. Charge from 20% to 80% through the USB power meter.
4. Record elapsed time, accumulated Wh, peak watts, and temperature observations.
5. Record segment times for 20-40%, 40-60%, and 60-80%.
6. Repeat at least twice.

Perform two versions:

- Phone locked and idle, establishing the best charging rate.
- Test app foreground with a black screen, measuring the resident app's overhead.

End the charging-speed comparison at 80%, because iOS intentionally slows charging as the battery approaches full.

### Phase 2: unplugged workload demand

Start near 80%. Stop at 20%, after four hours, or immediately on a safety condition.

| Test | Camera | Encoder/network | Snapshot comparison |
|---|---:|---:|---:|
| Foreground idle baseline | Off | Off | Off |
| On-demand standby | Off | Listener only | Off |
| Live 720p/10 FPS | On | On | Off |
| Live 720p/15 FPS | On | On | Off |
| Live 720p/30 FPS | On | On | Off |
| Live 1080p/15 FPS | On | On | Off |
| Cold snapshot every minute | Starts briefly | Listener only | On |
| Cold snapshot every five minutes | Starts briefly | Listener only | On |
| Warm-session snapshot control | Always on | Listener only | Every five minutes |

Start with the lowest live-video settings. Only test heavier profiles if the lower profiles remain stable.

Calculate practical discharge rate:

```text
discharge rate (%/hour) = battery percentage lost / elapsed hours
```

The observed runtime from 80% to 20% is more useful than an imprecise estimate of battery capacity in watt-hours.

### Phase 3: plugged sustainability

Start each run around 40-60%, not at 100%. Starting at 100% can conceal a small energy deficit.

For each promising workload:

1. Connect the selected Apple dual-port adapter through the USB meter, leaving its other port empty.
2. Run 30 minutes of warm-up.
3. Measure for another four hours.
4. Record battery slope, average input power, Wh, thermal state, FPS, dropped frames, and errors.
5. Repeat the test.

Classify a result as:

- **Pass:** battery gains at least about 2 percentage points over four hours, thermal state stays `nominal` or `fair`, and performance remains stable.
- **Marginal:** battery stays within about plus or minus 1%, leaving little power reserve.
- **Fail:** battery drops by more than about 1%, thermal state becomes `serious` or `critical`, charging pauses because of temperature, or camera/network stability is lost.

These percentage thresholds account for the coarse battery reading. Repeated results matter more than a single exact percentage.

The adapter's printed rating is its maximum capability, not the power forced into the phone; the phone controls its input. Use USB-meter measurements to determine the power actually delivered during each workload.

### Phase 4: hybrid duty-cycle test

Use a representative schedule such as:

- One cold snapshot every five minutes.
- One comparison per snapshot.
- Ten minutes of live viewing per hour.
- Listener and telemetry active continuously.

Run unplugged for four hours, then plugged for four hours.

Other use patterns can be estimated with:

```text
hybrid power ~= standby power
              + live duty cycle * (live power - standby power)
              + snapshot energy per hour
```

Estimate snapshot energy from a multi-hour run rather than one capture:

```text
energy per snapshot ~=
    (snapshot-run Wh - standby watts * run hours) / snapshot count
```

### Phase 5: soak testing

Only after a configuration passes the four-hour test:

1. Run a supervised 24-hour test.
2. Inspect the phone, cable, and connector.
3. Run a 72-hour test.
4. Finally, run a seven-day test.

A soak-test pass requires:

- No `serious` or `critical` thermal events.
- No charging-on-hold warnings.
- No crashes or unexplained capture interruptions.
- Sustainable battery percentage while plugged in.
- No increasing surface-temperature trend after thermal equilibrium.
- No physical battery changes.
- Acceptable frame delivery and reconnection behavior.

A seven-day pass demonstrates short-term operational stability, not permanent battery safety. Continue periodic physical inspection.

## Overall decision criteria

| Mode | Main measurement | Principal tradeoff |
|---|---|---|
| On-demand live | Standby power plus active-view duty cycle | Lowest work when rarely viewed, but no unattended anomaly detection |
| Continuous live | Live power, thermal plateau, and soak reliability | Best continuous coverage, with the greatest heat and battery-aging pressure |
| Snapshot hybrid | Standby power plus capture/comparison energy | Likely the best balance if cold capture and viewer transitions are reliable |

Compute annual wall energy from the USB meter:

```text
annual kWh = average watts * 8.76
```

For example, a measured 3 W average corresponds to approximately 26.3 kWh per year. Use measured wall power, not the adapter's printed maximum.

## Installing and running the tester on the iPhone 8

### Initial connection and signing

The iPhone must be connected to the Mac by cable at least once.

1. Update the iPhone 8 to the latest iOS version available to it.
2. Open Xcode on the Mac.
3. In **Xcode > Settings > Accounts**, add an Apple Account.
4. Create an iOS App project for `CameraCapabilityLab`.
5. Set its deployment target to the iOS version installed on the phone, or lower.
6. In the target's **Signing & Capabilities** tab:
   - Enable **Automatically manage signing**.
   - Select the Apple Account's Personal Team or paid developer team.
   - Use a unique bundle identifier, such as `com.example.CameraCapabilityLab`.
7. Connect the iPhone using a data-capable Lightning cable.
8. Unlock the phone and tap **Trust** when asked to trust the Mac.
9. In Xcode, open **Window > Devices and Simulators** and wait for device preparation to finish.
10. On the phone, enable **Settings > Privacy & Security > Developer Mode**. The phone will restart and request confirmation.
11. Select the iPhone as Xcode's run destination and press Run.
12. Accept the camera and local-network permissions when the app first launches.

A free Apple Account is sufficient for personal on-device testing, but Personal Team provisioning profiles expire after seven days. The app must then be rebuilt and installed again. A paid Apple Developer Program membership provides a less restrictive long-running workflow.

### Required privacy descriptions

Add these keys to the app target's Info settings:

- `NSCameraUsageDescription`: explain that the camera is used for capability and thermal testing.
- `NSLocalNetworkUsageDescription`: explain that the app sends test telemetry/video to the Mac.
- `NSBonjourServices`: add the service type used by `NWListener`, for example `_cameralab._tcp`.

Do not request microphone access during initial testing; audio is unnecessary and would add another power variable.

### Running without a cable

After the first USB pairing, Xcode may offer **Connect via network** in Devices and Simulators. Wireless debugging is useful during development, but do not use an attached debugger for formal energy tests.

For a formal run:

1. Install the current Release build.
2. Launch it once and verify permissions.
3. Stop the Xcode debugging session.
4. Disconnect the Lightning cable from the Mac.
5. Connect the phone to the test adapter through the inline USB meter.
6. Start the scenario from the phone.
7. Observe low-rate telemetry from the separate receiver app over Wi-Fi.
8. Export the phone's authoritative local log after the test.

The phone app should set `UIApplication.shared.isIdleTimerDisabled = true` only while a test is active. Keep it foregrounded with a black or very dim interface. Locking the phone or backgrounding the app makes precise recurring capture and inbound on-demand behavior unreliable.

Do not use `BGTaskScheduler` as a precise every-few-minutes snapshot timer. iOS decides when background work runs and can delay it substantially.

## Observing data on the Mac

Use three complementary observation paths.

### A. Xcode console for short development runs

During implementation, run from Xcode and use `Logger` from the `os` framework for state transitions and errors. The Xcode console is useful for debugging, but not for final energy measurements because the debugger and USB connection alter the test environment.

For short attached-device investigations, Xcode's Instruments can profile CPU time, allocations, network activity, and system behavior. Use these profiles to find expensive code, not as the authoritative charger-power measurement. The inline USB meter remains the source for watts and Wh. The macOS Console app can also display device and crash logs while the iPhone is connected.

### B. Live Wi-Fi telemetry for formal runs

During a formal test, send only a small JSON or newline-delimited JSON telemetry record every 10 seconds to `CameraLoadReceiver`.

The Mac receiver should display and save:

- Battery percentage and charging state.
- Thermal state.
- Current scenario and elapsed time.
- Camera/encoder/viewer states.
- Captured, dropped, encoded, and received frame counts.
- Transmitted and received bytes.
- Latest snapshot, comparison, and encoding durations.
- Camera, encoder, and network errors.

Keep telemetry low-rate so observing the test does not materially change its power profile.

### C. Local CSV/JSON export after the run

The phone's local log is the authoritative record. Add an Export button that presents `UIActivityViewController`, then AirDrop or save the run bundle to the Mac after testing. This preserves data even if Wi-Fi disconnects or the receiver crashes.

For an automated local-network alternative, add a post-run `EXPORT_RUN <run-id>` command to the test protocol so the receiver can download the completed file only after the timed measurement ends.

### External measurements

The Mac cannot infer charger watts or internal temperature from the telemetry stream. Enter USB-meter readings, ambient temperature, and rear-case temperature into the run notes or a companion CSV. Take surface readings from the same marked location each time.

## Safety-stop behavior

`TestCoordinator` should immediately stop the camera and encoder and mark the run failed when:

- `thermalState` becomes `critical`.
- `thermalState` remains `serious` for a configured short grace period.
- Capture repeatedly fails or the app receives a severe memory warning.
- The operator presses the stop button.

Also stop manually for a system temperature warning, charging-on-hold warning, swelling, screen lifting, odor, cable damage, or other physical abnormality.

There is no public exact battery-temperature value or universal rear-case temperature threshold. Use iOS thermal state, system warnings, controlled ambient conditions, and repeatable external temperature comparisons rather than inventing an internal-temperature estimate.

## References

- [Apple: Battery health and performance](https://support.apple.com/en-us/101575)
- [Apple: `UIDevice` battery monitoring](https://developer.apple.com/documentation/uikit/uidevice/isbatterymonitoringenabled)
- [Apple: thermal-state notifications](https://developer.apple.com/documentation/foundation/processinfo/thermalstatedidchangenotification)
- [Apple: `AVCaptureVideoDataOutput`](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput)
- [Apple: VideoToolbox compression sessions](https://developer.apple.com/documentation/videotoolbox/vtcompressionsession-api-collection)
- [Apple: `NWListener`](https://developer.apple.com/documentation/network/nwlistener)
- [Apple: Vision feature-print comparison](https://developer.apple.com/documentation/vision/vnfeatureprintobservation)
- [Apple: iPhone temperature behavior](https://support.apple.com/en-ie/118431)
- [Apple: choosing background-execution strategies](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)
- [Apple: enabling Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
- [Apple: developer-program membership comparison](https://developer.apple.com/support/compare-memberships/)
