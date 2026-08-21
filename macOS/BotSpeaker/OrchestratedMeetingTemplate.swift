import Foundation

struct OrchestratedMeetingTemplate: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let speakerRoles: [String]
    let defaultVoiceGenders: [String]
    let text: String

    var speakerCount: Int { speakerRoles.count }
    var turnCount: Int { (try? parsedTurns().count) ?? 0 }

    func parsedTurns() throws -> [OrchestratedScriptTurn] {
        try OrchestratedScriptParser.parse(text, speakerCount: speakerCount)
    }

    static let launchReadiness = OrchestratedMeetingTemplate(
        id: "meeting-assistant-launch-readiness",
        title: "AI meeting assistant launch readiness",
        detail: "4 speakers · natural launch decision",
        speakerRoles: ["Product Manager", "Engineering Lead", "Privacy & Security Lead", "Customer Success Lead"],
        defaultVoiceGenders: ["male", "female", "male", "female"],
        text: launchReadinessText
    )

    static let apiIncidentReview = OrchestratedMeetingTemplate(
        id: "api-latency-incident-review",
        title: "API latency incident review",
        detail: "3 speakers · operational retrospective",
        speakerRoles: ["Incident Commander", "Site Reliability Engineer", "Customer Support Lead"],
        defaultVoiceGenders: ["male", "female", "male"],
        text: apiIncidentReviewText
    )

    static let all = [launchReadiness, apiIncidentReview]

    private static let apiIncidentReviewText = """
    {{speaker_1}}: I am {{speaker_1}}, the Incident Commander for yesterday’s API latency event. This is a learning review, not a search for individual fault. We will reconstruct what customers experienced, identify where our detection and coordination helped or slowed us down, and leave with specific owners. The incident began at 9:42 a.m. Pacific when checkout requests in the western region started exceeding our two-second objective. We mitigated the customer impact at 10:31 and declared recovery at 10:47 after the queues drained. {{speaker_2}}, please start with the technical sequence.

    {{speaker_2}}: I am {{speaker_2}}, the Site Reliability Engineer who was primary on call. At 9:38, a routine configuration rollout increased the connection pool limit for the pricing service. The new limit looked safe in staging, but production traffic caused every application instance to open connections at nearly the same time. The database stayed available, yet lock contention increased sharply. Pricing calls slowed, checkout workers accumulated, and retries amplified the load. Our infrastructure alerts stayed green because CPU, memory, and error rate were normal. The first page came from the checkout latency objective at 9:46.

    {{speaker_3}}: I am {{speaker_3}}, the Customer Support Lead. Customers noticed before that page. The first chat arrived at 9:43 from a retailer whose checkout spinner ran for almost a minute. By 9:47 we had six similar contacts, but the tickets were split between payments, storefront, and general performance queues. The common pattern became obvious only when an agent posted the examples in the incident channel at 9:52. We should discuss why that customer signal did not reach the on-call team earlier.

    {{speaker_1}}: Agreed. First, on diagnosis: once the latency alert fired, what made the connection change difficult to identify?

    {{speaker_2}}: Two things. The rollout dashboard showed one hundred percent success because the configuration reached every instance and passed its health check. Also, our database dashboard emphasizes utilization and failed connections, not concurrent lock wait. I initially investigated the payment provider because its span was the slowest child in several traces. That was misleading: the provider span included time waiting for a worker thread. At 10:02 I compared a slow trace with the deployment timeline, and the pricing configuration was the only relevant change.

    {{speaker_3}}: That matches what Support saw. Some checkouts eventually completed, so agents hesitated to call it an outage. They described it as intermittent slowness, while customers described it as being unable to buy. We need severity guidance based on the user’s task, not only on HTTP failure rate.

    {{speaker_1}}: Yes. A checkout that takes forty seconds is functionally unavailable even if it returns status two hundred. When did we decide to roll back?

    {{speaker_2}}: At 10:08. I proposed the rollback after reproducing the lock wait in a production read replica. Approval took seven minutes because the configuration owner was not in the incident channel and our runbook still listed the previous team. The rollback began at 10:15, completed at 10:22, and latency improved immediately. We then reduced retry concurrency so the accumulated queue could drain without causing another spike.

    {{speaker_1}}: That approval delay is actionable. For a reversible configuration tied to an active severity-one symptom, the incident commander should be able to authorize rollback. We can notify the owning team in parallel. {{speaker_3}}, how did communication go during that window?

    {{speaker_3}}: The internal update was useful, but the public status message came too late. We posted at 10:12, twenty-nine minutes after the first customer report. The message said we were investigating elevated API latency, which was accurate but too broad. Checkout customers wanted to know whether retrying would create duplicate orders. Agents did not have an approved answer until 10:20. We should prepare symptom-specific language for delayed transactions and state clearly when retries are safe.

    {{speaker_2}}: For this event, duplicate orders were prevented by idempotency keys, but Support could not verify that from the dashboard. I can add an incident panel showing duplicate-suppression activity and queue depth. That would let the communication lead answer with evidence rather than waiting for an engineer.

    {{speaker_3}}: That would help. I also want ticket clustering to alert us when three enterprise customers report the same workflow symptom within ten minutes, even if they choose different categories. It should suggest a pattern to the duty lead, not automatically declare an incident.

    {{speaker_1}}: Good distinction. Let’s cover detection. {{speaker_2}}, what alert would have fired closest to the actual beginning without becoming noisy during normal peaks?

    {{speaker_2}}: A burn-rate alert on checkout duration segmented by region would have fired around 9:41. We already calculate that service-level indicator, but paging uses a fifteen-minute window. I propose a fast five-minute burn alert paired with queue growth, plus a dashboard for database lock-wait time. I do not recommend paging directly on connection count because healthy traffic bursts can produce the same shape.

    {{speaker_3}}: Can the alert include the affected customer workflow in plain language? “Checkout completion delayed in us-west” helps Support far more than a service identifier.

    {{speaker_2}}: Yes. The alert metadata can map the dependency to checkout and link the customer-impact dashboard. I’ll include that in the same change.

    {{speaker_1}}: Now prevention. The configuration itself was reviewed, so what test or rollout control was missing?

    {{speaker_2}}: Staging has too few application instances to reproduce the connection fan-out. We should validate aggregate connection demand as part of configuration review, cap the rollout to ten percent of production instances, and hold for ten minutes while comparing lock wait and checkout latency. The deployment controller can automatically halt if either metric regresses. I also want the connection pool limit expressed as a regional budget divided among instances instead of a fixed per-instance number.

    {{speaker_3}}: From the customer side, I want a short follow-up for affected accounts that explains the symptom, confirms that completed orders were not duplicated, and names the prevention work without exposing internal details. We should send it to the forty-two accounts that crossed the delay threshold, not to every customer.

    {{speaker_1}}: Agreed. Let me summarize the actions. {{speaker_2}} owns the canary rollout guard, regional connection budget, lock-wait dashboard, and faster checkout burn alert by next Friday. I own the rollback authority update and the service ownership audit by Wednesday. {{speaker_3}} owns the ticket-pattern proposal, support guidance for delayed transactions, and targeted customer follow-up by Monday. We will test the revised runbook in a game day within two weeks.

    {{speaker_2}}: That captures my items. I’ll also attach the query and trace evidence from this review so the alert thresholds can be evaluated against the actual incident.

    {{speaker_3}}: Mine too. I’ll include the frontline agents who handled the first contacts in the communication review; they saw the ambiguity before the rest of us did.

    {{speaker_1}}: Perfect. The main lesson is that availability must be measured at the customer workflow, not inferred from healthy infrastructure. We recovered safely, but detection, rollback authority, and customer guidance were slower than they should have been. Thank you both. I’ll publish the review with these owners and dates today.
    """

    private static let launchReadinessText = """
    {{speaker_1}}: I am {{speaker_1}}, the Product Manager for Decision Digest. Thanks for making the time. The purpose of this review is to decide whether our AI meeting assistant is ready for a controlled launch, not to defend a date we already picked. I want a direct answer on product value, reliability, privacy, and customer operations. If the answer is conditional, we will name the conditions, owners, and stop signals before we leave. For context, the first cohort is five design partners using post-meeting summaries for scheduled internal meetings. The assistant drafts decisions, action items, and open questions, and every item links back to transcript evidence. Nothing is sent automatically to task systems or external recipients.

    {{speaker_2}}: I am {{speaker_2}}, the Engineering Lead. That scope matches what we have tested. The service is stable at pilot volume, and the architecture gives us a clean kill switch before a transcript enters generation. My current recommendation is a conditional go. Two technical gates remain: the export event must appear reliably in the workspace audit log, and the batching optimization must finish its live canary without moving the quality metrics. Those are bounded pieces of work, but I do not want us to blur “nearly merged” with “production evidence.”

    {{speaker_3}}: I am {{speaker_3}}, the Privacy and Security Lead. I agree with the conditional framing. My question is slightly different: can an attendee understand that processing is happening, and can we honor a withdrawal without asking support to improvise? Administrator enablement is necessary, but it is not enough for a live conversation. We require an organizer action, persistent attendee notice, a recorded notice-delivery event, and a hard rejection when notice delivery fails. I also need one end-to-end deletion exercise that starts with a participant request and ends with verified removal of the derived digest, embeddings, and temporary inference artifacts.

    {{speaker_4}}: I am {{speaker_4}}, the Customer Success Lead. From the customer side, there is real pull. Pilot teams repeatedly tell us they recover ten to fifteen minutes after a planning meeting, especially when action items are scattered across chat and personal notes. But they also call the draft “the record” unless we teach them otherwise. I support the five-customer cohort if the product and launch materials consistently call it an editable, transcript-linked draft. Support needs a capability matrix, an escalation path, and a clear answer for an attendee who says, “I did not want this summary created.”

    {{speaker_1}}: Good. Let me test the value proposition against those boundaries. We are promising faster follow-through with evidence, not perfect minutes and not an autonomous source of truth. The organizer reviews before sharing. External meetings, webinars, coaching scores, regulated templates, and automatic task creation remain out of scope. Are we comfortable that this is still useful enough for the cohort, or have the safeguards removed the reason customers wanted it?

    {{speaker_4}}: It is still useful. Actually, the review step is part of the appeal for the administrators I spoke with. They do not want another bot silently publishing tasks. They want a strong first draft and a quick way to verify attribution. One caveat: the empty-state copy should say why a digest was blocked when notice validation fails. If it just says “generation unavailable,” administrators will open tickets and may retry in ways that confuse attendees.

    {{speaker_2}}: Yep, that is straightforward. We already expose a structured rejection reason internally. We can map the notice-validation case to customer-safe copy without exposing infrastructure details. I will add that to the launch branch and include it in the end-to-end test.

    {{speaker_3}}: That works for me, with one wording review. Please avoid implying the attendee caused the failure. Something like, “The digest was not created because attendee notice could not be confirmed.” It is factual and it reinforces the safeguard.

    {{speaker_1}}: Agreed. Now latency. Our pilot median is about six seconds after the meeting ends, the ninety-fifth percentile is just under fifteen, and the long tail reaches the high twenties. The launch promise says the draft appears shortly after the call. Do we need a full week of production shadowing, or is forty-eight hours enough?

    {{speaker_2}}: Forty-eight hours is enough if we define the evidence before the clock starts. The batching change groups compatible transcript windows and removes queue overhead. Replay on ten thousand pilot meetings brought the ninety-fifth percentile below eleven seconds with no measurable drop in grounding or action-item precision. I want forty-eight hours of shadow traffic, one canary organization, language-segmented quality, and a rollback exercise. If any comparison crosses the threshold, the clock resets. Waiting seven days after clean evidence would add calendar time, not confidence.

    {{speaker_3}}: I’m comfortable with that. Is regional isolation included in the comparison? A latency win is not acceptable if a fallback can send content outside the workspace’s configured region.

    {{speaker_2}}: Yes. Batches are formed only inside the organization and region boundary. Admission queues work rather than borrowing capacity from another region. We have an alert on any attempted routing mismatch, and the canary dashboard breaks that out separately.

    {{speaker_3}}: Great. Then no objection from me on forty-eight hours.

    {{speaker_4}}: One operational question: when the kill switch stops new jobs, what does a customer see for meetings already waiting? “Processing” forever would be worse than a clear delay state.

    {{speaker_2}}: In-flight jobs either finish on the pinned version or move to “delayed by administrator control,” depending on where they are in the pipeline. We do not discard the source meeting. Once the hold is lifted, eligible jobs resume. I can give Support the exact state table and screenshots before training.

    {{speaker_4}}: Perfect. That gives us something concrete to practice.

    {{speaker_1}}: Let’s cover language scope. English, Spanish, and French meet the agreed thresholds. German action-item recall is still several points below English, although precision remains high. My proposal is to keep all four languages in the cohort, label non-English output as beta, and make the readiness dashboard language-specific. Thoughts?

    {{speaker_4}}: I would keep German for two of the five customers because they explicitly joined to test it. Removing it now loses useful evidence. But the account team must say “beta” before enablement, and the weekly report must show omissions by language rather than one blended satisfaction score.

    {{speaker_3}}: I agree, provided the label is visible where the digest is reviewed, not buried in an administrator document. Also, a language regression should pause that language independently. We should not disable healthy English processing because German recall drops, and we should not hide German risk inside a healthy global average.

    {{speaker_2}}: We can gate by language. The classifier change recovers four points in replay, and the deployment system already supports a language allowlist. I will add per-language stop thresholds to the launch configuration.

    {{speaker_1}}: Sounds aligned. Privacy, walk us through the withdrawal test and what would make you say no-go.

    {{speaker_3}}: The test begins as a real request, not a database command. Customer Success submits the request through the documented channel with a meeting identifier and participant context. We verify authorization, delete the entire derived digest, remove processing artifacts, and record acknowledgments from every subsystem. The source recording follows the customer’s separate retention policy, so the confirmation must not claim we deleted that too. I will say no-go if notice failure can still enter generation, if derived content survives beyond the documented window, if support needs privileged engineering access to complete the request, or if audit evidence contains transcript excerpts rather than identifiers and event types.

    {{speaker_4}}: I’d like Support to run the request while Engineering observes. That proves the procedure works for the team who will actually receive it.

    {{speaker_2}}: Agreed. We will instrument the exercise, but we won’t take over the steps. If the runbook cannot be followed without an engineer at the keyboard, it has not passed.

    {{speaker_1}}: Excellent. Let’s turn to audit logging. Today an organizer can copy or export a digest, but the workspace audit log does not reliably record every export path. I consider that a hard launch gate because administrators use the log to investigate where meeting content went.

    {{speaker_3}}: Strong agreement. Viewing and exporting are different risk events. We need actor, workspace, digest identifier, export type, and timestamp. No transcript text in the event. Failed export attempts should be distinguishable from completed exports, and the retention must match the customer’s audit policy.

    {{speaker_2}}: The event is implemented for download and copy. The remaining path is the share-sheet handoff. It will be in Thursday’s build. We can test all three paths against an isolated workspace and attach the resulting audit records to the launch checklist.

    {{speaker_4}}: That also makes support conversations easier. When an administrator asks whether a digest left the product, we can point them to evidence instead of guessing from application logs.

    {{speaker_1}}: All right. I’m hearing four launch conditions: complete export auditing, pass the forty-eight-hour latency canary and rollback exercise, pass notice and withdrawal tests end to end, and finish customer-facing training with the exact states and claims. Is anything missing?

    {{speaker_2}}: Capacity reservation. It is already arranged, but it belongs in the signed record. The first cohort has reserved model-provider capacity and thirty percent headroom at the expected peak. If quota falls below that buffer, admission slows before quality or isolation is compromised.

    {{speaker_4}}: Add an escalation roster with one named engineering lead and one Customer Success owner each business day. A dashboard without a person watching it is not a launch control.

    {{speaker_3}}: And each function needs authority to trigger a hold. The launch commander makes the final coordination call, but Engineering, Privacy, Security, or Customer Success should not need consensus to stop expansion when its threshold is crossed.

    {{speaker_1}}: Yes to all three. Here is the decision I’ll record: conditional go for five customers, not unrestricted availability. {{speaker_2}} owns export auditing, canary evidence, capacity confirmation, and rollback. {{speaker_3}} owns notice and deletion verification plus the privacy wording. {{speaker_4}} owns cohort checklists, training, and the escalation roster. I own the capability statement, launch record, and daily review. Expansion pauses automatically on any stop threshold, and we reconvene after five hundred production digests.

    {{speaker_4}}: That is clear. I’ll have the customer checklist and simulated support cases ready by Monday.

    {{speaker_3}}: Conditional approval from me, assuming the evidence is attached rather than summarized as a checkbox.

    {{speaker_2}}: Same here. I’ll publish the canary dashboard and rollback timeline so everyone can review the raw result.

    {{speaker_1}}: Great. Then we have a decision. We are launching a reviewable assistant that reduces administrative work while keeping evidence and participant control visible. We are not launching an autonomous record keeper. I’ll send the decision log today with owners, dates, and stop conditions. Thanks, everyone.
    """
}

struct OrchestratedScriptTurn: Hashable {
    let speakerIndex: Int
    let text: String
}

struct OrchestratedSpeakerConfiguration: Identifiable, Hashable {
    let slot: Int
    let role: String
    var name: String
    var voiceID: String
    var voiceName: String

    var id: Int { slot }
    var placeholder: String { "{{speaker_\(slot)}}" }
}

enum OrchestratedScriptParser {
    static func parse(_ text: String, speakerCount: Int) throws -> [OrchestratedScriptTurn] {
        let pattern = #"^\{\{speaker_(\d+)\}\}\s*:\s*(.+)$"#
        let expression = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let paragraphs = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var turns: [OrchestratedScriptTurn] = []
        for (offset, paragraph) in paragraphs.enumerated() {
            let range = NSRange(paragraph.startIndex..., in: paragraph)
            guard let match = expression.firstMatch(in: paragraph, range: range),
                  match.range == range,
                  let speakerRange = Range(match.range(at: 1), in: paragraph),
                  let bodyRange = Range(match.range(at: 2), in: paragraph),
                  let oneBasedIndex = Int(paragraph[speakerRange]),
                  (1...speakerCount).contains(oneBasedIndex) else {
                throw AppError("Paragraph \(offset + 1) must start with {{speaker_1}} through {{speaker_\(speakerCount)}} followed by a colon.")
            }
            turns.append(OrchestratedScriptTurn(
                speakerIndex: oneBasedIndex - 1,
                text: String(paragraph[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        guard !turns.isEmpty else { throw AppError("The orchestrated meeting script is empty.") }
        return turns
    }
}
