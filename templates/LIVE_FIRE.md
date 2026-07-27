# LIVE_FIRE.md — ledger of intentional live-fire (irreversible external action) paths

This file registers any path in this repo that **intentionally** fires live
fire (SMS, voice calls, email, payments, orders, physical control, or any other
irreversible external action).

Under live-fire control, demo, test, and mock code paths must never fire live
fire (sink sealing). But some code paths have a genuine business need for "the
real thing to actually fire" — a sales demo where a prospect needs to see a
real call land, for example. Those paths aren't banned; they're placed under
control as a **registered exception** instead. Any file registered here must
also be added to `.forge/sinks-allow.txt` (so the CI sweep passes).

Fill in every field below for each path. In particular, "current state of each
guard layer" must say **specifically which layers are live and which are
down** — not just "disabled." A real incident happened because "disabled" was
later discovered to mean only that a contact record had been deactivated, not
that the vendor credential had been revoked; the team believed the path was
inert when it was one config change away from firing for real.

---

## Entry format (copy this whole section per path)

### Path name: <e.g. Live call trigger from the public demo page>

- **Endpoint / function:** `<e.g. POST /api/demo/trigger/{token} -> _fire_demo_notification>`
- **Sink:** `<e.g. notifier.notify() -> sns_service.send_notification / connect_service.make_call>`
- **Destination:** `<e.g. a registered demo contact (placeholder tenant ID; not a real customer or vendor)>`
- **Legitimate need:** `<why does this have to fire for real? e.g. a live sales demo needs the prospect to see a real call land>`
- **Guard layers and current state of each:**
  - Layer 1 (<e.g. auth>): <e.g. none — token match only, no authentication — recognized weakness>
  - Layer 2 (<e.g. token>): <e.g. DEMO_TRIGGER_TOKEN match, set in the production secret store — currently live>
  - Layer 3 (<e.g. destination contact>): <e.g. contact id=13, is_active=**0 (deactivated — currently a blank round)**>
  - Overall state: <e.g. blank round (layer 3 is down, so reaching this endpoint does not actually send anything). Re-enabling layer 3 alone would make this live again.>
- **Re-arming procedure:** `<e.g. temporarily enable remote exec -> update_notification_contact(13, is_active=True) -> disable again immediately after>`
- **Authorization record:** `<e.g. 2026-07-22, armed for a live demo, disarmed again afterward per explicit instruction>`
- **Open items:** `<e.g. token rotation/expiry for layer 2 and adding layer 1 auth are both still outstanding>`

---

<!-- List actual registered paths below. If there are none, state "No registered paths" explicitly. -->
