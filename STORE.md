# Shipping SPLICE

What is built, and exactly what is left for you. The short version: the app is
complete and produces release artifacts for both stores. Everything remaining
requires *your* accounts, *your* money, and *your* legal identity — none of
which can be delegated.

---

## What you must provide

| | Cost | Why it can't be automated |
|---|---|---|
| Apple Developer Program | **$99/year** | Requires your Apple ID and a legal entity/individual identity check |
| Google Play Console | **$25 one-time** | Requires your Google account and identity verification |
| Android upload keystore | free | A permanent credential you must own and back up |
| Privacy policy URL | free | Must be hosted somewhere you control |

---

## Current configuration

- **Bundle / application ID**: `com.splicegame.splice`
  Change this **before** first upload if you want your own domain — it is
  permanent once published on either store. To change it:
  `dart run change_app_package_name:main com.yourdomain.splice` (Android) and
  edit `PRODUCT_BUNDLE_IDENTIFIER` in Xcode (iOS).
- **Display name**: SPLICE
- **Orientation**: portrait only
- **Minimum Android SDK**: 21 · **Minimum iOS**: as per Flutter default (13.0)

### Privacy — read this before submitting

The game itself collects nothing: run records live in `shared_preferences` on
the device and never leave it. **But the rewarded-ad revive changes the
picture**, because the Google Mobile Ads SDK collects device identifiers and
usage data.

You can no longer answer "No data collected" on either store.

**Google Play — Data Safety form**

- Data collected: **Device or other IDs**, **App activity** (app interactions)
- Purpose: **Advertising or marketing**
- Shared with third parties: **Yes** (Google AdMob)
- Encrypted in transit: yes · Users can request deletion: link to AdMob's policy

**Apple — App Privacy**

- **Identifiers → Device ID**, used for **Third-Party Advertising**
- **Usage Data → Product Interaction**, used for **Third-Party Advertising**
- Answer **Yes** to "tracking" if you serve personalised ads. That obliges you
  to call `AppTrackingTransparency` before requesting a personalised ad;
  `NSUserTrackingUsageDescription` is already in `Info.plist`.

**Also required**

- A **privacy policy URL** is now mandatory on both stores, not optional.
- **EU/UK users need a consent flow** (GDPR). AdMob's UMP SDK handles this;
  it is not wired up yet — see the gaps list.
- If you ever set the age rating to target children, AdMob requires
  `tagForChildDirectedTreatment` and a child-safe ad content filter.

**If you would rather keep "No data collected"**, remove the
`google_mobile_ads` dependency, delete `lib/src/core/ads.dart`, and drop the
`GADApplicationIdentifier` / `APPLICATION_ID` entries. The revive button hides
itself automatically when no ad service is available, so nothing else breaks.

### Ad unit IDs

The app ships with **Google's public test IDs**, so the revive works out of the
box, serves non-earning test ads, and cannot accidentally bill a real account.
Before release, swap in your own:

```sh
flutter build appbundle --release \
  --dart-define=ADMOB_REWARDED_ANDROID=ca-app-pub-XXXX/YYYY \
  --dart-define=ADMOB_REWARDED_IOS=ca-app-pub-XXXX/ZZZZ
```

and replace the app IDs in `ios/Runner/Info.plist` (`GADApplicationIdentifier`)
and `android/app/src/main/AndroidManifest.xml`
(`com.google.android.gms.ads.APPLICATION_ID`). Both are commented in place.

**Shipping with the test IDs will get the app rejected or earn nothing** —
Google explicitly prohibits serving test ads in production.

---

## Android → Google Play

### 1. Create the upload keystore

**Read this before running it.** The keystore signs every update to your app.
If you lose it, you can never update the listing again under that package name
— you would have to publish a new app and lose your install base. Back it up
somewhere durable and put the password in a password manager.

```sh
keytool -genkey -v \
  -keystore ~/splice-upload-key.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias upload
```

Then create `android/key.properties` (already covered by `.gitignore` — never
commit it):

```properties
storePassword=<what you typed>
keyPassword=<what you typed>
keyAlias=upload
storeFile=/Users/maksimsmirnov/splice-upload-key.jks
```

The Gradle config in `android/app/build.gradle.kts` already reads this file and
falls back to debug signing when it is absent, so the project builds either way.

### 2. Build

```sh
flutter build appbundle --release
# → build/app/outputs/bundle/release/app-release.aab
```

### 3. Listing assets you must supply

- App icon **512×512** PNG — use `art/icon.png`, downscaled
- Feature graphic **1024×500** — not generated; this one needs a designer or a
  simple text-on-background composition
- **At least 2** phone screenshots — see `store/screenshots/` (generated)
- Short description (≤80 chars) and full description (≤4000) — drafts below
- Content rating questionnaire — the game has stylised, non-realistic violence
  against abstract creatures; expect PEGI 7 / ESRB E10+
- Data safety form — **not** "No data collected"; see the Privacy section above

---

## iOS → App Store

### 1. Register the bundle ID

In the Apple Developer portal, create an App ID matching
`com.splicegame.splice`, then create the app record in App Store Connect.

### 2. Sign and archive

```sh
open ios/Runner.xcworkspace
```

In Xcode: select **Runner → Signing & Capabilities**, set your Team, let Xcode
manage signing. Then **Product → Archive**, and **Distribute App → App Store
Connect**.

A pre-flight unsigned build is already verified:

```sh
flutter build ios --release --no-codesign
```

### 3. Reduce the screenshot burden

The project is currently **universal** (iPhone + iPad), which means Apple will
demand iPad screenshots too. Unless you want to support iPad, set the target to
iPhone only in Xcode (**Runner → General → Supported Destinations**, remove
iPad). Then you only need 6.9" iPhone screenshots.

### 4. Listing assets you must supply

- App icon **1024×1024**, no alpha — already generated at `art/icon.png` and
  wired into the asset catalogue
- Screenshots at **1320×2868** (6.9" iPhone) — see `store/screenshots/`
- App privacy: device ID + usage data for third-party advertising; see the
  Privacy section above
- Export compliance: the app uses **no encryption** → answer "No" to the
  encryption question
- Age rating questionnaire — same as Android: infrequent/mild cartoon violence

---

## Draft store copy

Yours to edit — you know your audience better than I do.

**Short description (80 chars max):**

> Breed your abilities. The swarm evolves to resist whatever you rely on.

**Full description:**

> SPLICE is a top-down survival game about evolution — yours and theirs.
>
> You don't pick upgrades from a list. Every ability is an organism with a
> genome: how it delivers, what it does on contact, what makes it fire, and any
> number of stacking modifier genes. When you level up, you breed two of your
> abilities together. The offspring inherits from both parents — splice an
> Orbit with a Beam and it orbits *and* fires a beam — plus a mutation that
> nobody designed, including the developer.
>
> Breeding two of the same kind concentrates it instead: no hybrid, but raw
> power. Hybrid vigour buys coverage. Pure lineage buys damage.
>
> Meanwhile the swarm is adapting. Whatever damage type kills the most of them,
> they grow resistant to. Lean on one build and it will strangle you. Keep
> breeding diversity, or find the genes that strip resistance away.
>
> - Ability combinations with no ceiling — modifier genes stack without a cap
> - An evolving enemy swarm that counters your dominant strategy
> - One-thumb controls; your abilities fire themselves
> - Every creature and effect generated procedurally from code
> - No forced ads and no in-app purchases — one optional rewarded revive per run

---

## Honest gaps

Things I could not verify or complete, so you know where to look:

1. **The audio is unheard.** I synthesised every sound from scratch and can
   confirm the waveforms are well-formed, correctly enveloped, and not
   clipping — but I have no way to listen to them. Play the game with sound on
   and expect to want changes. All of it regenerates from `tools/audio.py`;
   the per-sound volume trims in `lib/src/core/audio.dart` let you rebalance
   without re-synthesising anything.
2. **Balance is untested by a human.** The numbers are internally consistent
   and a 12-minute simulated run behaves, but "is it fun, and is the
   difficulty curve right" needs you playing it. The tuning constants worth
   reaching for first are at the top of `lib/src/game/world.dart`
   (spawn rate, HP scaling, adaptation rate) and in `lib/src/genome/genome.dart`
   (`subVectorPower`, purity bonuses, generation scaling).
3. **No feature graphic.** Play requires a 1024×500 banner; that is a design
   task rather than a generated one.
4. **Not tested on physical hardware.** Verified on the iOS Simulator only.
   Test on a real device — particularly the audio latency and the frame rate
   with a screen full of enemies — before submitting.
5. **No GDPR consent flow.** Serving personalised ads to EU/UK users requires
   Google's UMP consent SDK, which is not wired up. Until it is, either add it
   or restrict distribution outside the EEA/UK.
6. **iOS ATT prompt is not requested.** The usage-description string is in
   place, but nothing calls `AppTrackingTransparency` yet. Without it iOS
   serves only non-personalised ads, which is compliant but earns less.
