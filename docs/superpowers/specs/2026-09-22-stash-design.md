# Stash — design

**Datum:** 2026-09-22
**Status:** goedgekeurd door Brent, klaar voor implementatieplan
**Bundle id:** `be.vernast.Stash`
**Doel-OS:** macOS 27.0 (build 26A428), Apple Silicon

---

## 1. Probleem

Ice (`com.jordanbaird.Ice`, geïnstalleerd 0.11.12) verbergt op macOS 27 geen menubalk-items meer.
Dat is geen bug in Ice maar het gevolg van een herschrijving in het besturingssysteem.

Tot macOS 26 tekende macOS elk status item als een eigen venster. Dat was nooit een
gepubliceerde API, maar het gaf ontwikkelaars houvast: je kon die vensters opsommen via
`CGWindowList`, ze screenshotten met ScreenCaptureKit en ze buiten beeld duwen. De hele
categorie — Ice, Bartender, Hidden Bar, Dozer — leunde op dat implementatiedetail.

macOS 27 tekent de balk als **één venster**. Er valt niets meer op te sommen. Daarnaast:

- Een `NSStatusItem` waarvan het achterliggende venster (lengte + 16pt chrome) de **halve
  schermbreedte** haalt, wordt uit de layout **gegooid** in plaats van geclampt. De klassieke
  truc "blaas een spacer op tot 10.000pt zodat alles links ervan van het scherm valt" duwt
  daardoor niets meer. Gemeten door derden op een 1728pt-scherm: 848pt verbergt, 849pt niet
  (848 + 16 = 864 = 1728 / 2).
- De nieuwe engine kent een notie van *supported* status items en weigert de rest. Op deze
  machine gemeten, letterlijk uit `MenuBarAgent`:

  ```
  [com.apple.menubar:statusItems] Filtering out unsupported status item: com.jordanbaird.Ice
  ```

  34 keer in één minuut. Ice's spacer-items worden actief uit de balk gefilterd.

macOS 27 heeft wél een eigen overloopknop (`•••`) die inklapt wanneer iconen niet meer passen,
maar die kiest zelf wat er weggaat. Er is geen ondersteunde manier om per app te bepalen wat
verborgen wordt.

## 2. Wat er wél werkt — gemeten, niet aangenomen

macOS 27 bevat de faciliteit achter **assessment mode** (de examenmodus die scholen gebruiken om
de balk kaal te zetten). Die werkt als **allowlist**: je houdt een assertion vast die opsomt welke
apps zichtbaar mogen zijn, en het systeem tekent de rest niet.

Oppervlak, geverifieerd op deze machine via `dlopen` + Objective-C runtime:

```
/System/Library/PrivateFrameworks/MenuBarClientCore.framework   → dlopen OK

MBAssessmentModeConfiguration
  -initWithAllowedSystemItems:allowedBundleIdentifiers:
  -allowedSystemItems
  -allowedBundleIdentifiers

MBAssessmentModeAssertion
  -activateWithConfiguration:completionHandler:
  -activate:completion:
  -activateWithCompletionHandler:
  -invalidate
```

### Bewijs uit de probe (22-09-2026)

Wegwerp-CLI, ad-hoc gecompileerd in de scratchpad, allowlist leeg (= alles verbergen wat kan):

```
voor:    ☕ ◈ ⋔ ☁15°C ••• ✳ 🪐 wifi vol 🖥 ⚙ 10:23     (12 items)
tijdens:                    ✳    wifi vol    ⚙ 10:21     ( 5 items)
na:      ☕ ◈ ⋔ ☁15°C ••• ✳ 🪐 wifi vol 🖥 ⚙ 10:23     (12 items)
```

Systeemlog tijdens diezelfde run:

```
probe5[10321] [com.apple.menubar:visibility-restriction-xpc-client]
              Attempting to activate VisibilityRestrictionAssertion session
              VisibilityRestrictionAssertion session activated
MenuBarAgent  [com.apple.menubar:visibilityRestriction] didActivateVisibilityRestriction
MenuBarAgent  [com.apple.menubar:statusItems] No server elements for status item: "com.jordanbaird.Ice"
MenuBarAgent  [com.apple.menubar:statusItems] No server elements for status item: "com.raycast.macos"
MenuBarAgent  [com.apple.menubar:statusItems] No server elements for status item: "pro.betterdisplay.BetterDisplay"
MenuBarAgent  [com.apple.menubar:statusItems] No server elements for status item: "com.vorssaint.utils"
MenuBarAgent  [com.apple.menubar:statusItems] No server elements for status item: "org.pqrs.Karabiner-Console-User-Server"
MenuBarAgent  [com.apple.menubar:statusItems] No server elements for status item: "com.apple.weather.menu"
MenuBarAgent  [com.apple.menubar:statusItems] No server elements for status item: "com.apple.Passwords.MenuBarExtra"
MenuBarAgent  [com.apple.menubar:analytics] MenuBar.trailingItems.count payload=["count": 5]
MenuBarAgent  [com.apple.menubar:analytics] MenuBar.trailingItems.count payload=["count": 12]   (na invalidate)
```

Vastgesteld, tegen de verwachting op basis van vergelijkbare projecten in:

| Vraag | Antwoord |
|---|---|
| Entitlement nodig? | Nee |
| Code signing nodig? | Nee — ad-hoc gecompileerde CLI werkte |
| App in `/Applications`? | Nee — draaide vanuit de scratchpad |
| Screen Recording / Accessibility? | Nee, geen enkele prompt |
| Schoon herstel? | Ja, `invalidate()` én procesexit zetten alles exact terug |
| Bereik systeemitems | Boven 63. Met range 0–63 verdween Screen Mirroring ongewild; met 0–255 blijft alles staan |

`MBAssessmentModeConfiguration` accepteert alleen `NSArray`; een `NSSet` gooit een exception.

## 3. Scope

**Wel:**
- Een chevron in de balk. Klik = verborgen apps verschijnen, klik weer = weg.
- Een instellingenvenster met een vinkje per app.
- Automatisch weer inklappen na een instelbare tijd.
- Starten bij inloggen.

**Niet** — dit zijn grenzen van de faciliteit, geen keuzes:
- **Per app, niet per icoon.** Eén app met drie status items gaat als geheel weg.
- **Geen herordenen.** De allowlist bepaalt of iets getekend wordt, niet waar.
- **Geen tweede balk of paneel** met de verborgen iconen erin. Die techniek (vensters opsommen,
  screenshotten, clicks doorsturen) bestaat niet meer op macOS 27.

**Niet in v1, bewust:**
- Fallback op de spacer-truc. Die is op 27 half kapot (ejectie boven halve schermbreedte, groeien
  moet in stapjes van ~40pt omdat één sprong de buren niet meeneemt) en kost meer dan hij opbrengt.
  Zie §9 voor wat er wél gebeurt als de private API wegvalt.
- App Store-distributie. De faciliteit is privé; dit wordt nooit een Store-app.

## 4. Architectuur

Vijf units, elk met één verantwoordelijkheid en een expliciete grens.

| Unit | Verantwoordelijk voor | Weet niets van |
|---|---|---|
| `MenuBarShim` (ObjC) | `dlopen`, runtime-lookup, de twee private klassen inpakken | Swift-model, UI |
| `MenuBarRestriction` | assertion-levenscyclus: activeren, vervangen, invalideren | voorkeuren, UI |
| `AppInventory` | draaiende apps volgen, bundle ids leveren, launch/quit signaleren | verbergen |
| `HiddenSet` | welke bundle ids verborgen horen te zijn, persistentie | het OS |
| `StatusItemController` + `SettingsView` | chevron, toggle, timer, vinkjeslijst | private API's |

### 4.1 `MenuBarShim` — Objective-C, apart SwiftPM-target

Swift kan private Objective-C klassen alleen via `NSClassFromString` + `perform(_:with:with:)`
aanroepen, wat typeloos en broos is. Een dun ObjC-target eromheen geeft Swift een normale,
getypeerde API en houdt alle `dlopen`-rommel op één plek. SwiftPM ondersteunt geen gemengde
targets, dus dit is een eigen target waar het Swift-target van afhangt.

```objc
@interface STMenuBarShim : NSObject
/// NO als het framework of een van de klassen ontbreekt. Roep dit één keer aan bij start.
+ (BOOL)isAvailable;

/// Activeert een nieuwe assertion. completion krijgt nil bij succes.
/// Geeft een opaque token terug dat je aan -invalidate: meegeeft.
+ (nullable id)activateWithAllowedBundleIdentifiers:(NSArray<NSString *> *)bundleIDs
                                  allowedSystemItems:(NSArray<NSNumber *> *)systemItems
                                          completion:(void (^)(NSError *_Nullable))completion;

+ (void)invalidate:(id)token;
@end
```

### 4.2 `MenuBarRestriction` — Swift

```swift
protocol MenuBarRestricting {
    var isAvailable: Bool { get }
    func apply(allowing bundleIDs: Set<String>) async throws
    func clear()
}
```

`apply` is idempotent en vervangt de vorige toestand. Volgorde binnen `apply`:

1. Nieuwe assertion activeren met de nieuwe allowlist.
2. Pas ná een succesvolle completion de oude invalideren.

Die volgorde staat er om flikkeren te voorkomen: de balk mag geen moment zonder actieve
restrictie zitten, anders springen alle iconen even terug. **Open punt voor fase 1:** of twee
assertions tegelijk mogen bestaan is niet gemeten. Zo niet, dan wordt het invalidate-dan-activate
en accepteren we een frame flikkering; de test in §8.1 stelt dit vast vóór de rest gebouwd wordt.

`allowedSystemItems` is altijd `0...255`. Nooit 0...63 — dan verdwijnt Screen Mirroring.

### 4.3 `AppInventory`

```swift
protocol AppInventoryObserving: AnyObject {
    func inventoryDidChange(_ inventory: AppInventory)
}

final class AppInventory {
    /// Bundle ids van alles wat nu draait en een status item kán hebben.
    var runningBundleIDs: Set<String> { get }
    /// Alles wat ooit gezien is, voor de lijst in het instellingenvenster.
    var knownApps: [KnownApp] { get }   // bundleID, naam, icoon, laatstGezien
}
```

Abonneert op `NSWorkspace.shared.notificationCenter`:
`didLaunchApplicationNotification` en `didTerminateApplicationNotification`.

### 4.4 `HiddenSet`

Pure waarde plus persistentie in `UserDefaults` onder `be.vernast.Stash.hiddenBundleIDs`.
Geen OS-kennis, volledig unit-testbaar.

### 4.5 `StatusItemController`

Eigen `NSStatusItem` met een chevron (`chevron.left` ingeklapt, `chevron.right` uitgeklapt).
Linkermuisknop togglet, rechtermuisknop opent een menu met Instellingen en Stop.

## 5. Toestand en dataflow

Twee toestanden. Meer niet.

```
                    klik chevron  /  ⌥⌘S
     ┌──────────────┐ ───────────────────────► ┌──────────────┐
     │  INGEKLAPT   │                          │  UITGEKLAPT  │
     │              │ ◄─────────────────────── │              │
     └──────────────┘  klik chevron / timer    └──────────────┘
                       / app verliest focus
```

De allowlist die bij elke toestand hoort:

```
ingeklapt   = AppInventory.runningBundleIDs − HiddenSet + [eigen bundle id]
uitgeklapt  = AppInventory.runningBundleIDs           + [eigen bundle id]
```

Het eigen bundle id staat er altijd bij; anders verbergt de app z'n eigen chevron en kun je niet
meer terug.

Elke wijziging in `AppInventory` of `HiddenSet` herberekent de allowlist en roept `apply` aan.

### De valkuil die dit ontwerp moet ontwijken

De allowlist is een momentopname van bundle ids, geen regel. Start je een app ná het inklappen,
dan staat die niet in de allowlist en **verdwijnt hij ongevraagd** — de app lijkt dan willekeurig
programma's op te vreten en je zoekt je rot. `AppInventory` bestaat uitsluitend om dat te
voorkomen: elke launch herbouwt de allowlist. Dit is de belangrijkste correctheidseis in het hele
ontwerp en krijgt een eigen test (§8.2).

## 6. Instellingenvenster

SwiftUI, één venster, drie stukken:

1. **Lijst met apps** — naam, icoon, vinkje "verbergen". Gesorteerd op naam. Apps die niet meer
   draaien blijven in de lijst staan (grijs, "niet actief") zodat je keuze niet verdwijnt als je
   een app afsluit.
2. **Automatisch inklappen** — uit / na 5s / 10s / 30s / bij focusverlies.
3. **Start bij inloggen** — `SMAppService.mainApp`.

Welke apps een menubalk-item hébben is zonder Accessibility niet te weten. v1 toont daarom alle
draaiende apps met een bundle id en een `activationPolicy` van `.regular` of `.accessory`. Dat is
een ruimere lijst dan nodig, maar vraagt geen permissie. Een optionele Accessibility-filter is een
latere verbetering, geen v1-eis.

## 7. Bouw en distributie

Er staat **geen Xcode** op deze machine, alleen Command Line Tools met Swift 6.4. Dat is genoeg:

```
Package.swift            targets: MenuBarShim (ObjC, c99), Stash (Swift, executable), StashTests
Makefile                 build → Stash.app bundelen → codesign -s -
Resources/Info.plist     LSUIElement = true (geen Dock-icoon)
Resources/Stash.icns
```

`make install` kopieert naar `/Applications`. Ad-hoc signing volstaat; de probe bewees dat de
faciliteit geen signing of Developer ID vereist.

## 8. Testen

### 8.1 Integratietest voor de assertion — de OS-log als orakel

`MenuBarAgent` logt zelf hoeveel items er in de balk staan:

```
[com.apple.menubar:analytics] MenuBar.trailingItems.count payload=["count": 12]
```

De test activeert een assertion met een bekende allowlist, leest met
`log show --last 15s --predicate 'subsystem == "com.apple.menubar"'` de count terug en vergelijkt.
Dat is echt bewijs uit het systeem zelf, geen screenshot-vergelijking en geen aanname.

Dezelfde test beantwoordt het open punt uit §4.2: activeer twee assertions na elkaar zonder
tussentijdse invalidate en kijk of de tweede de eerste vervangt of ernaast bestaat.

### 8.2 Unit-tests zonder OS

- `HiddenSet`: toevoegen, verwijderen, persisteren, herladen.
- Allowlist-berekening: gegeven inventory + verborgen set + toestand → verwachte allowlist.
  Inclusief het geval **"nieuwe app gestart terwijl ingeklapt"** — die hoort in de allowlist te
  belanden, niet erbuiten.
- Eigen bundle id zit altijd in de allowlist, in beide toestanden.

### 8.3 Handmatige verificatie per fase

Screenshot van de balk vóór, tijdens en na, met `screencapture -x -D 1` plus een crop. Dat is hoe
de probe van 22-09 is geverifieerd en het blijft de eindcontrole voor elke fase.

## 9. Risico's

| Risico | Kans | Antwoord |
|---|---|---|
| Apple verwijdert of wijzigt `MenuBarClientCore` | reëel bij elke .1-update | `isAvailable` checkt bij start. Faalt het: chevron toont een waarschuwingsicoon, app verbergt niets, geen crash. Eén plek om te repareren. |
| Assertion kan niet vervangen worden zonder flikkering | onbekend | Vastgesteld in fase 1 door §8.1, vóór de rest gebouwd wordt |
| Assessment mode heeft neveneffecten buiten de balk | laag — niets waargenomen in de probe | Fase 1 draait 10 minuten met actieve assertion en controleert Control Center, Spotlight, Focus |
| App crasht met actieve assertion | laag | Procesexit ruimt de assertion op; de probe bevestigde dat de balk terugkomt |
| Apps met meerdere status items gaan als geheel | zeker | Gedocumenteerd in het instellingenvenster, geen oplossing mogelijk |

## 10. Fasering

1. **`MenuBarShim` + `MenuBarRestriction`** — assertion activeren, vervangen, invalideren.
   Integratietest §8.1. Beantwoordt het open punt over dubbele assertions.
2. **`AppInventory` + `HiddenSet`** — allowlist-berekening met unit-tests, inclusief de
   launch-tijdens-ingeklapt-casus.
3. **`StatusItemController`** — chevron, toggle, auto-inklappen.
4. **`SettingsView`** — app-lijst met vinkjes, timer-instelling.
5. **Bundelen** — Makefile, Info.plist, icoon, `SMAppService`, `make install`.

Elke fase eindigt met een draaiende app en een screenshot-verificatie.
