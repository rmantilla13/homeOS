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
- [ ] Bring up the RK3588 board, Armbian, and Qt on EGLFS
- [ ] Hardware video decode through GStreamer and Rockchip MPP
- [ ] Wake on mmWave presence, auto-brightness, night mode
- [ ] systemd kiosk service, watchdog, logging

## M3: Polish and family features
- [ ] Recurring chores generated nightly (edge function plus cron)
- [ ] Google and iCloud calendar sync
- [ ] Push notifications: chore reminders, approval requests
- [ ] Albums, "on this day" memories, video playback on the wall
- [ ] Meal-plan to shopping-list generation

## M4: Custom device
- [ ] Carrier board for an RK3588 compute module, with bonded panel and enclosure
- [ ] Yocto image, A/B OTA updates, secure boot
- [ ] Voice: local wake word on the NPU, plus commands
