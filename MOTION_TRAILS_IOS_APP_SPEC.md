# Motion Trails iOS App Specification

## 1. Product Summary

Motion Trails is a consumer iOS and iPadOS app for creating short, social-ready videos where moving subjects leave realistic trails across a mostly static scene.

The user places the device in a secure fixed position, usually on a tripod, records a short clip, and the app composites only meaningful motion changes into an accumulating output video. The intended result is a playable video where birds, athletes, vehicles, pets, insects, or other fast-moving subjects appear to leave repeated photographic silhouettes or paths through the frame.

The app is not a social network. Its primary value is capture, edit, export, and share.

## 2. Product Goals

- Produce realistic motion-trail videos from short fixed-camera recordings.
- Keep the capture workflow simple enough for casual users.
- Support orientation-neutral capture, with social crop presets handled during edit.
- Prioritize sharp, high-quality trails over battery life.
- Support minor tripod movement compensation.
- Allow post-capture editing by retaining the source recording and project settings.
- Monetize with a freemium model based on recording length, watermark removal, and advanced creative/export features.

## 3. Non-Goals For MVP

- In-app social feed or user profiles.
- Scheduled recording.
- Background recording while the app is closed or the phone is locked.
- Pause/resume capture.
- Cloud storage or cloud processing.
- User-uploaded source video processing.
- Full manual professional camera suite.
- Scientific measurement, object classification, or analytics.

## 4. Target Users

Primary users:

- Creators who want unusual short-form visual effects for social media.
- Wildlife and bird watchers capturing motion paths.
- Parents, pet owners, and hobbyists capturing action scenes.
- Sports and action users capturing movement paths.

Secondary users:

- Photographers experimenting with long-exposure-like effects in daylight.
- Coaches or instructors who want visual motion paths, provided the creative output quality is good enough.

## 5. Supported Platforms

Target platforms:

- iPhone.
- iPad.

Compatibility goal:

- Broad support across devices from roughly the last 10 years, subject to App Store, Xcode, OS, camera, and performance constraints.

Device behavior should be capability-gated:

- Older devices may record at lower frame rates, lower preview resolution, or slower render speed.
- Newer devices may unlock higher frame rates, faster live preview, better stabilization, and 4K export.

## 6. Core User Workflow

### 6.1 Capture Flow

1. User opens the app.
2. User frames the scene in any orientation.
3. App allows camera auto-exposure, focus, and white balance to settle.
4. App performs a short stability check.
5. App warns if the device appears handheld or unstable.
6. App locks focus, exposure, and white balance.
7. User starts recording.
8. App records a short high-frame-rate source video.
9. App shows an accumulated trail preview if performance allows.
10. App stops automatically at the selected maximum duration or when the user taps stop.

### 6.2 Edit Flow

1. User enters an edit screen after capture.
2. App displays the generated trail video preview.
3. User adjusts trail settings.
4. User optionally selects a social crop format.
5. App re-renders from the retained source video and settings.
6. User exports or shares the result.

### 6.3 Project Flow

1. Each capture creates a local project.
2. Projects retain the source video, render settings, generated exports, and metadata.
3. Projects are retained indefinitely unless the user deletes them.

## 7. MVP Functional Requirements

### 7.1 Capture

- The app shall record source video rather than repeated still photos.
- The app shall support sub-second motion sampling.
- The app shall prefer 1080p recording for MVP.
- The app shall prefer high-frame-rate capture where supported.
- The app shall support recording durations suitable for 10-20 second captures.
- The app shall support a hard recording duration limit for the free tier.
- The app shall work only while open and active.
- The app shall not support scheduled capture in MVP.
- The app shall not support pause/resume capture in MVP.

### 7.2 Camera Configuration

- The app shall allow automatic focus, exposure, and white balance to settle before recording.
- The app shall lock focus, exposure, and white balance during recording.
- The app shall prefer short exposure times to reduce motion blur.
- The app shall warn users when the scene is too dark for sharp trail capture.
- The app should expose basic capture quality settings only when useful and understandable.

### 7.3 Stability Detection

- The app shall perform a pre-recording stability check.
- The app shall warn users when device motion suggests handheld use.
- The app shall allow users to continue despite warnings.
- The app should use camera-frame analysis and device motion data when available.

### 7.4 Motion Trail Generation

- The app shall generate a playable video showing trails building over time.
- The app shall use a visually static background as the default.
- The app shall detect meaningful pixel or region changes between frames.
- The app shall ignore small noisy changes.
- The app shall compensate for minor camera movement.
- The app shall accumulate detected moving pixels into a composite frame.
- The app shall output each accumulated state as a video frame.
- The app shall use realistic replacement-style trails as the default compositing mode.

### 7.5 Editing

- The app shall allow post-capture edits.
- The app shall re-render from the retained source video.
- The app shall support sensitivity adjustment.
- The app shall support minimum motion size adjustment.
- The app shall support stabilization strength adjustment.
- The app shall support background mode selection between static and slowly updating.
- The app shall support social crop presets during edit.
- The app shall support export speed or output duration adjustment.

### 7.6 Export And Sharing

- The app shall export MP4 video suitable for social sharing.
- The default export shall be 1080p.
- The app shall support common aspect ratios:
  - Original orientation.
  - 9:16 vertical.
  - 1:1 square.
  - 4:5 portrait.
  - 16:9 landscape.
- The app shall use the iOS share sheet for sharing.
- The free tier shall apply a watermark.

## 8. Paid Feature Requirements

Paid or premium features should include:

- Longer recording duration.
- Watermark removal.
- 4K export where supported.
- Ignore-region masks.
- Trail fade controls.
- Overlay/blend compositing modes.
- Creative color trails.
- Presets for different subject types.
- Cloud project sync/storage.
- User-uploaded video processing.

## 9. Important Product Decisions

### 9.1 Video Frames Instead Of Still Photos

The app should capture video frames, not frequent still photos.

Reasoning:

- Fast subjects need dense temporal sampling.
- Repeated still capture is too slow and inconsistent for smooth trails.
- Video capture gives predictable frame timing.
- High-frame-rate video is better suited to fast subjects like birds.
- Source video can be retained for re-rendering.

### 9.2 Replacement As Default Compositing

Default compositing should copy changed subject pixels into an accumulated frame.

Replacement behavior:

- If a moving subject is detected at a pixel, that pixel from the current frame is written into the accumulated image.
- If that same pixel is later occupied by another moving subject, the newer pixel replaces the older pixel.
- The result is clean, photographic, and realistic.

Overlay behavior:

- A moving pixel is blended with existing accumulated content.
- This can preserve overlapping trails but creates a more ghosted or stylized result.
- This should be treated as a creative premium mode, not the MVP default.

### 9.3 Ignore Regions During Edit

Ignore-region masks should be created during edit for the first paid implementation.

Reasoning:

- The source video is retained, so masks can be applied after capture and re-rendered.
- Edit-time masking is easier for users because they can see the generated problem areas first.
- Setup-time masking can be added later if testing shows users need to exclude known areas before capture.

## 10. Technical Architecture

### 10.1 Recommended App Architecture

The app should be built as a native Swift app.

Recommended layers:

- SwiftUI presentation layer.
- Capture service using AVFoundation.
- Processing pipeline using GPU-accelerated image operations.
- Project storage service.
- Export service using AVAssetWriter or equivalent video export APIs.
- Monetization service for free/premium capability checks.

### 10.2 Capture Service

Responsibilities:

- Configure camera session.
- Select best supported resolution and frame rate.
- Lock camera settings.
- Stream frames for preview and processing.
- Write the source recording to local project storage.
- Report dropped frames, exposure warnings, and stability warnings.

Preferred capture design:

- Use a video data output for frame access.
- Use a writer pipeline to persist the original source video.
- Process a lower-resolution proxy for live preview.
- Preserve full-resolution source for final render.

### 10.3 Processing Service

Responsibilities:

- Decode source frames.
- Stabilize frames against a reference.
- Build or update a background reference.
- Compute motion masks.
- Clean masks by removing noise and small regions.
- Composite changed pixels into an accumulator.
- Generate preview frames and final export frames.

### 10.4 Export Service

Responsibilities:

- Render the accumulated trail sequence to MP4.
- Apply crop/aspect settings.
- Apply watermark rules.
- Save export to the project.
- Save to Photos or share through the iOS share sheet.

### 10.5 Project Storage

Each project should include:

- Project identifier.
- Creation date.
- Source video file.
- Optional proxy video or preview assets.
- Render settings.
- Exported videos.
- Thumbnail.
- Basic metadata.

Projects should be stored locally and retained indefinitely by default.

## 11. Processing Pipeline Detail

### 11.1 Frame Acquisition

For final render:

1. Read frames from the retained source video.
2. Normalize orientation.
3. Apply crop only after processing unless testing proves crop-first improves quality or performance.
4. Convert frames into the processing color format.

For live preview:

1. Receive live frames from capture.
2. Downscale to a preview resolution.
3. Process preview frames with the same settings where practical.
4. Display approximate accumulated result.

### 11.2 Reference Background

Default mode:

- Use an initial clean frame or short early-frame estimate as the static background.
- Keep the background visually stable during render.

Optional mode:

- Slowly update the background over time.
- This can handle gradual lighting changes but may reduce the purity of persistent trails.

### 11.3 Stabilization

The app should compensate for minor device movement.

Initial implementation:

- Estimate frame-to-reference translation or affine transform.
- Apply the transform before motion detection.
- Expose stabilization strength during edit.

Advanced future implementation:

- More robust feature matching.
- Rolling-shutter-aware correction if needed.
- Per-region stabilization for difficult scenes.

### 11.4 Motion Detection

Initial implementation should use configurable frame/background difference:

- Compare luminance and color difference.
- Build a motion mask from pixels above threshold.
- Apply temporal smoothing where useful.
- Remove speckles and tiny changes.
- Fill small gaps inside detected subject regions.

User-facing controls:

- Sensitivity.
- Minimum motion size.

Internal tunables:

- Difference threshold.
- Morphological cleanup strength.
- Temporal consistency requirement.
- Edge preservation.

### 11.5 Compositing

Default persistent replacement:

1. Start with the static background frame.
2. For each processed frame, detect moving pixels.
3. Copy moving pixels from the current frame into the accumulated frame.
4. Encode the accumulated frame into the output video.

Optional fade:

- Store an age or opacity value per accumulated pixel or region.
- Reduce contribution over time.
- Treat as premium due to added complexity and creative value.

Optional overlay:

- Blend current moving pixels with existing accumulated pixels.
- Treat as premium creative mode.

## 12. User Interface Specification

### 12.1 Main Capture Screen

Required elements:

- Live camera preview.
- Record button.
- Duration indicator.
- Stability status indicator.
- Lighting/shutter quality warning.
- Current max recording length.
- Access to recent projects.

Preferred behavior:

- Show accumulated proxy preview during recording if device performance allows.
- If live trail preview is not possible, show live camera plus a lightweight recording status and generate preview immediately after capture.

### 12.2 Pre-Capture Stability Warning

States:

- Stable.
- Minor movement detected.
- Unstable / handheld likely.

The app should not block recording by default. It should warn clearly and allow users to continue.

### 12.3 Edit Screen

Required controls:

- Playback preview.
- Sensitivity slider.
- Minimum motion size slider.
- Stabilization control.
- Background mode selector.
- Crop/aspect selector.
- Output speed/duration control.
- Export/share button.

Premium controls:

- Ignore-region mask editor.
- 4K export selector.
- Fade controls.
- Blend/compositing modes.
- Color trail styles.

### 12.4 Project Library

Required elements:

- Thumbnail grid or list.
- Project date.
- Duration.
- Export status.
- Delete action.
- Reopen edit action.

## 13. Monetization Model

Recommended model:

- Free tier:
  - Short recording length.
  - 1080p export.
  - Watermarked exports.
  - Core realistic persistent trail effect.

- Paid unlock:
  - Longer recordings.
  - Watermark removal.
  - 4K export where supported.
  - Ignore-region masks.
  - Creative trail styles.
  - Fade and blend controls.
  - Future cloud storage and uploaded video processing.

The free tier should be good enough to prove the effect and encourage sharing, but constrained enough that frequent users have a reason to upgrade.

## 14. Data And Storage Requirements

The app shall store:

- Source video.
- Render settings.
- Generated export video.
- Project thumbnail.
- Project metadata.

The app should not store every decoded raw frame by default.

Storage implications:

- Source videos can become large even for short captures.
- Indefinite retention requires a clear project library and delete controls.
- The app should show storage usage or warnings once local project storage becomes significant.

Potential future storage features:

- User-controlled project cleanup.
- iCloud or app-cloud sync.
- Export-only archive mode.
- Cloud processing for large uploaded videos.

## 15. Privacy Requirements

- MVP should process locally on device.
- Source videos and generated exports should remain local unless the user explicitly shares or enables cloud features.
- The app should explain local project storage clearly.
- Camera and Photos permissions should use clear purpose strings.

## 16. Performance Requirements

MVP targets:

- Smooth capture without dropped frames on supported devices.
- Live preview should never compromise source capture.
- Final render quality is more important than render speed.
- 1080p export should complete in a tolerable time for 10-20 second captures.

Performance strategy:

- Use lower-resolution proxy processing for live preview.
- Use full source resolution for final render.
- Use GPU acceleration where practical.
- Capability-gate high frame rate, 4K, and expensive stabilization.

## 17. Quality Requirements

The generated output should:

- Preserve a mostly static background.
- Create realistic trails from moving subjects.
- Avoid obvious speckle noise.
- Avoid excessive false positives from small lighting shifts.
- Handle minor camera movement.
- Export in formats accepted by common social platforms.

The app should communicate limitations:

- Strong camera shake reduces quality.
- Low light causes blur or noise.
- Moving foliage, water, reflections, and shadows may be detected as motion unless masked or tuned.
- Very fast subjects may require high frame rate and strong lighting.

## 18. Presets

Presets are not required for MVP unless testing shows object types need materially different settings.

Candidate future presets:

- Birds.
- Sports.
- Pets.
- Traffic.
- Insects.
- Long-action scene.

Each preset would map to:

- Sensitivity.
- Minimum motion size.
- Stabilization default.
- Background behavior.
- Preferred frame rate.
- Suggested capture duration.

## 19. MVP Scope

MVP should include:

- Native iOS/iPadOS app.
- Camera capture.
- Orientation-neutral recording.
- 1080p source/output target.
- Short source video capture.
- Camera setting lock.
- Stability warning.
- Static background trail generation.
- Minor stabilization.
- Realistic replacement compositing.
- Edit controls for sensitivity, minimum motion size, stabilization, background mode, crop, and output speed.
- Local project storage with indefinite retention.
- MP4 export.
- Share sheet.
- Free-tier watermark and recording length limit.

MVP should exclude:

- Cloud storage.
- Uploaded video processing.
- Manual mask editing.
- 4K export.
- Trail fade.
- Creative color modes.
- Advanced presets.
- Background recording.

## 20. Suggested Build Phases

### Phase 1: Technical Prototype

Goal:

- Prove that the trail effect is visually compelling.

Scope:

- Record short 1080p clips.
- Generate static-background persistent trails.
- Export MP4.
- Test birds, traffic, pets, and sports examples.

Success criteria:

- Trails are recognizable and realistic.
- Background remains acceptably static.
- Noise is manageable with simple thresholds.
- Minor camera movement can be corrected enough for tripod use.

### Phase 2: MVP App

Goal:

- Ship the core user workflow.

Scope:

- Capture UI.
- Stability warning.
- Camera locking.
- Project storage.
- Edit screen.
- Re-rendering.
- Social crop/export.
- Watermark and free recording limit.

Success criteria:

- A casual user can record, edit, export, and share without technical knowledge.
- Output quality is high enough for repeated social use.

### Phase 3: Premium Features

Goal:

- Add paid reasons to upgrade.

Scope:

- Longer recordings.
- Watermark removal.
- 4K where supported.
- Ignore-region masks.
- Fade and blend modes.
- Creative color styles.

Success criteria:

- Paid features materially improve creative control.
- Free users still understand the app's core value.

### Phase 4: Expansion

Goal:

- Broaden use cases and retention.

Scope:

- Cloud project sync/storage.
- Uploaded video processing.
- Presets.
- More advanced stabilization.
- More advanced motion segmentation.

## 21. Risks And Mitigations

### 21.1 Low Light And Fast Motion

Risk:

- High shutter speed needs light. Low light will create blur or noise.

Mitigation:

- Warn users before recording.
- Prefer bright outdoor use.
- Offer quality indicators.
- Allow lower frame rate or longer exposure only as a deliberate tradeoff.

### 21.2 False Motion Detection

Risk:

- Shadows, trees, water, clouds, and reflections may be detected.

Mitigation:

- Tune sensitivity and minimum motion size.
- Add background update mode.
- Add paid ignore-region masks.
- Add presets later if testing shows clear differences.

### 21.3 Camera Shake

Risk:

- Handheld capture or tripod movement creates whole-frame changes.

Mitigation:

- Stability pre-check.
- Minor stabilization.
- Clear warnings.
- Edit-time stabilization strength.

### 21.4 Live Preview Performance

Risk:

- Real-time full-quality processing may drop frames or hurt capture quality.

Mitigation:

- Use proxy preview.
- Prioritize source capture.
- Fall back to post-capture preview on older devices.

### 21.5 Local Storage Growth

Risk:

- Indefinite project retention consumes storage.

Mitigation:

- Project library with delete controls.
- Storage usage indicators.
- Future archive/export-only modes.

## 22. Open Questions

- What exact free recording duration should be used?
- Should watermark size and placement be subtle or intentionally visible?
- Should crop happen before render for performance, or after render for maximum edit flexibility?
- What minimum deployment target is practical once App Store and performance constraints are confirmed?
- Should the first prototype use simple thresholding only, or include stabilization from day one?
- What app name and visual identity should be used?

## 23. Recommended MVP Defaults

- Capture resolution: 1080p.
- Capture duration: 10-20 seconds typical.
- Frame rate: best supported high frame rate, with 60fps as a practical default target.
- Output: MP4, H.264, 1080p.
- Output frame rate: 30fps default, 60fps optional where useful.
- Background: static.
- Trail mode: persistent replacement.
- Preview: lower-resolution proxy.
- Processing: local on-device.
- Storage: retain source projects indefinitely.
- Monetization: free length limit plus watermark; paid unlocks longer recording and watermark removal first.

