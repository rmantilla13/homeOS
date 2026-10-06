# Roadmap

## M0: Foundations (this scaffold)
- [x] Architecture, hardware choice and roadmap
- [x] Database schema with RLS, points ledger and reward redemption
- [x] Display app shell: navigation, Home, Calendar, Tasks, Rewards, Photos,
      Planner, and idle photo-frame mode (demo data)
- [x] iOS app skeleton: tabs, Supabase client, photo upload, pairing screen
- [x] `pair-device` edge function

## M1: Live data
- [ ] Display: device login and token refresh, live reads through `SupabaseClient`
- [ ] Display: Realtime subscriptions (events, tasks, completions, media)
- [ ] Display: SQLite offline cache and write queue
- [ ] iOS: Sign in with Apple, family creation and invites
- [ ] iOS: create and edit events, tasks and rewards; approve completions

## M2: Hardware prototype
- [x] Pi 5 install script, kiosk service, on-screen keyboard, compact layout for the 10.1" panel
- [x] Docker simulator of the device (Debian arm64 + VNC)
- [ ] First boot on the real Pi 5 + 10.1" panel (EGLFS, touch, HDMI audio)
- [ ] Video playback in the photo frame (HEVC hardware decode)
- [ ] Wake on mmWave presence, auto-brightness, night mode
- [ ] Watchdog and remote logging

## M2.5: Design and assistant
- [x] New visual style: warm canvas, line icons, blue accent, blue/coral/amber glow, pastel member colors
- [x] Calendar with Day, Week (time grid) and Month views
- [x] Family assistant on the home screen (Claude, grounded in family data and family memory, with action tools)
- [x] Dynamic time-of-day palette and photo-driven colors
- [x] Smooth page transitions and micro-animations
- [x] Media page (photos and videos, month groups, full-screen viewer with video playback)
- [ ] Assistant in the iOS app
- [ ] Voice input (speech-to-text) and spoken replies

## M3: Polish and family features
- [ ] Recurring chores generated nightly (edge function plus cron)
- [ ] Google and iCloud calendar sync
- [ ] Push notifications: chore reminders, approval requests
- [ ] Albums, "on this day" memories, video playback on the wall
- [ ] Meal-plan to shopping-list generation

## M4: Custom device
- [ ] Carrier board for the Raspberry Pi Compute Module 5, with bonded panel and enclosure
- [ ] Yocto image, A/B OTA updates, secure boot
- [ ] Voice: local wake word (CPU or AI HAT+), plus commands
