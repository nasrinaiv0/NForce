# NForce Award-Readiness Guide

**Status:** Research and planning resource. Winning an award is never guaranteed; this guide maps what juries reward to concrete, testable work.  
**Last updated:** 2026-11-23. Award programs change categories and deadlines every year, so verify on the official site before entering.

## 1. Which awards fit a workforce app

| Program | Why it fits NForce | What juries reward | Official site |
| --- | --- | --- | --- |
| **Apple Design Awards** | Flagship iOS craft award. Categories in 2026: Delight and Fun, Inclusivity, Innovation, Interaction, Social Impact, Visuals and Graphics. Utility apps win (e.g. *Tide Guide* won Visuals and Graphics in 2026). | Native feel, platform technologies, accessibility, polish | [developer.apple.com/design/awards](https://developer.apple.com/design/awards/) |
| **Google Play Best of** (annual, regional) | Includes productivity and large-screen/wear form-factor awards. Winners are picked per region, so Philippines/APAC is a realistic target. | Quality, Material You, large screens, broad device support | [blog.google (Best of Play 2026)](https://blog.google/products-and-platforms/platforms/google-play/best-of-play-awards-2026) |
| **Webby Awards** — Apps & Software | Public + academy-judged digital excellence; has productivity/business categories | Content, structure, navigation, visual design, functionality, interactivity | [webbyawards.com](https://www.webbyawards.com/) |
| **Red Dot Award: Brands & Communication Design** (Apps / UI) | International design seal widely used in marketing | Innovation, aesthetic quality, functionality, usability | [red-dot.org](https://www.red-dot.org/) |
| **iF Design Award** — UX / UI disciplines | Large international jury; enterprise products regularly win | Idea, form, function, differentiation, impact | [ifdesign.com](https://ifdesign.com/) |
| **Stevie Awards for Great Employers** — *Workforce Management Solution* (new product and implementation tracks) | A category made for this product | Measurable customer outcomes, innovation | [hr.stevieawards.com](https://hr.stevieawards.com/awards/categories/solutions-implementations-categories) |
| **Lighthouse Tech Awards** (formerly HR Tech Awards) — Core HR & Workforce | Analyst-judged HR-tech recognition (~1–2% of 5,000+ vendors) | Customer impact, differentiation, evidence | [lhra.io](https://lhra.io/) |
| **HR Executive Top HR Products** | Shown at the HR Technology Conference | Novelty, value to HR, usability | [hrexecutive.com](https://hrexecutive.com/) |
| **Brandon Hall Group HCM Excellence** | Long-running HCM program | Documented business results | [brandonhall.com](https://brandonhall.com/) |
| **G2 / Gartner Peer Insights / SoftwareReviews** (customer-voted) | Buyer-trusted badges for WFM software | Verified customer reviews and satisfaction | [g2.com](https://www.g2.com/), [gartner.com/peer-insights](https://www.gartner.com/peer-insights), [softwarereviews.com](https://www.softwarereviews.com/) |

**Suggested sequence:** customer-voted badges and the HR-tech awards need real customers and outcome data, so plan them after pilots. Apple Design Awards, Google Play Best of, Webby, Red Dot and iF can be pursued once the native apps are in the stores with the polish items in §3 done.

## 2. Standards and guidelines to build against

| Area | Resource |
| --- | --- |
| iOS design | [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/), [SF Symbols](https://developer.apple.com/sf-symbols/), [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) |
| Android design | [Material Design 3](https://m3.material.io/), [Android core app quality](https://developer.android.com/docs/quality-guidelines/core-app-quality), [Large-screen app quality](https://developer.android.com/docs/quality-guidelines/large-screen-app-quality), [Wear OS quality](https://developer.android.com/docs/quality-guidelines/wear-app-quality) |
| Accessibility | [WCAG 2.2](https://www.w3.org/TR/WCAG22/), [Apple Accessibility](https://developer.apple.com/accessibility/), [Android accessibility](https://developer.android.com/guide/topics/ui/accessibility), [Microsoft Inclusive Design toolkit](https://inclusive.microsoft.design/) |
| Human-centred process | ISO 9241-210 (human-centred design), [Nielsen Norman 10 usability heuristics](https://www.nngroup.com/articles/ten-usability-heuristics/) |
| Performance | [Android vitals](https://developer.android.com/topic/performance/vitals), [Xcode Organizer / MetricKit](https://developer.apple.com/documentation/metrickit), [React Native performance](https://reactnative.dev/docs/performance), [Expo docs](https://docs.expo.dev/) |
| Mobile security | [OWASP MASVS / MASTG](https://mas.owasp.org/), [OWASP ASVS](https://owasp.org/www-project-application-security-verification-standard/) |
| Privacy | Apple [privacy nutrition labels](https://developer.apple.com/app-store/app-privacy-details/), Google Play [Data safety](https://support.google.com/googleplay/android-developer/answer/10787469), Philippine Data Privacy Act ([privacy.gov.ph](https://privacy.gov.ph/)), GDPR |
| Trust certifications (enterprise buyers) | SOC 2 Type II, ISO/IEC 27001 |
| Localization | [Unicode CLDR](https://cldr.unicode.org/), platform `Intl` APIs |

## 3. Readiness scorecard

Legend: ✅ implemented and verified in this repo · 🟡 partially done · ⬜ not started

| Jury criterion | NForce today | Next action |
| --- | --- | --- |
| **Native feel** | ✅ Native tab bars (Liquid Glass / M3), native stacks with iOS large titles, form sheets, SF Symbols + Material Symbols, ripple vs spring feedback, platform-correct controls | Run on device. Add iOS context menus and Android predictive-back animations per screen |
| **Visual craft** | ✅ Token-based dual design system, light/dark, branded icon set, hero moments used sparingly | Professional design QA; motion pass with the reduced-motion variants |
| **Interaction** | ✅ Haptics, optimistic updates, live timers, inline validation, pull-to-refresh | Widgets / Live Activity for an active shift; Apple Watch & Wear OS clock-in |
| **Inclusivity** | 🟡 Labels, roles, states, live regions, font scaling to 2×, 44/48 touch targets, reduced motion, 3 languages | VoiceOver/TalkBack audits on device, RTL language (Arabic), color-contrast audit, Switch/Voice Control testing |
| **Social impact** | 🟡 Fair-by-design rules: day-off never eats leave balance, no self-approval, transparent server time, auditable corrections | Measure outcomes with pilots (fewer payroll disputes, approval turnaround); privacy-preserving attendance options |
| **Innovation** | ⬜ | Permission-aware AI assistant ("cover Friday's shift"), fairness-aware scheduling suggestions (Phase 7) |
| **Reliability / quality** | ✅ Strict TS, 0-warning lint, 56 core + 14 app tests, 21 SQL security tests, CI | Crash reporting + performance monitoring (Sentry or similar), E2E tests (Maestro) on both platforms |
| **Security & privacy** | ✅ RLS on every table, tenant-safe composite FKs, immutable attendance/audit, idempotent RPC | MASVS review, pen test, privacy labels, data-retention jobs, SOC 2 roadmap |
| **Performance** | 🟡 React Compiler, native-driver animations, code splitting, timers paused in background | Measure cold start, TTI and frame rate on low-end Android. Set budgets in CI |
| **Customer evidence** (HR-tech awards) | ⬜ | Pilot customers, case studies, before/after metrics |

## 4. Submission kit checklist

- [ ] App Store & Play listings with localized screenshots (both flavors, light/dark) and a 30-second preview video.
- [ ] Accessibility statement and audit report.
- [ ] Privacy and security one-pager (RLS, immutable audit, data residency).
- [ ] Outcome metrics from pilots (time-to-approve, payroll corrections, adoption).
- [ ] Design story: the problem, who it serves (frontline staff, supervisors, HR), and what is novel.
- [ ] Award calendar with deadlines (check each official site annually).

## Sources consulted (2026)

- Apple Newsroom — [Apple reveals winners of the 2026 Apple Design Awards](https://www.apple.com/newsroom/2026/06/apple-reveals-winners-of-the-2026-apple-design-awards/)
- MacStories — [2026 Apple Design Award finalists](https://www.macstories.net/news/apple-announces-its-2026-apple-design-award-finalists/)
- Google — [Best of Google Play 2026](https://blog.google/products-and-platforms/platforms/google-play/best-of-play-awards-2026)
- Stevie Awards — [Great Employers solutions categories](https://hr.stevieawards.com/awards/categories/solutions-implementations-categories)
- Lighthouse Research — [HR Tech Awards](https://lhra.io/blog/hr-tech-awards-2025-winners-announced/)
- HR Executive — [2026 Top HR Products recap](https://hrexecutive.com/?p=165532)
