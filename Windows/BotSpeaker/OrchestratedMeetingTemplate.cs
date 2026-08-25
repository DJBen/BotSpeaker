using System.Text.RegularExpressions;

namespace BotSpeaker;

public sealed record OrchestratedScriptTurn(int SpeakerIndex, string Text);

public sealed class OrchestratedSpeakerConfiguration
{
    public required int Slot { get; init; }
    public required string Role { get; init; }
    public string Name { get; set; } = "";
    public string VoiceId { get; set; } = "";
    public string VoiceName { get; set; } = "";
    public string Placeholder => $"{{{{speaker_{Slot}}}}}";
}

public sealed record OrchestratedMeetingTemplate(
    string Id,
    string Title,
    string Detail,
    IReadOnlyList<string> SpeakerRoles,
    IReadOnlyList<string> DefaultVoiceGenders,
    string Text)
{
    public int SpeakerCount => SpeakerRoles.Count;
    public int TurnCount => ParseTurns(Text).Count;

    public List<OrchestratedScriptTurn> ParseTurns(string text)
    {
        var paragraphs = Regex.Split(text.Replace("\r\n", "\n").Trim(), @"\n\s*\n")
            .Select(value => value.Trim())
            .Where(value => value.Length > 0)
            .ToList();
        var result = new List<OrchestratedScriptTurn>();
        for (int index = 0; index < paragraphs.Count; index++)
        {
            var match = Regex.Match(
                paragraphs[index],
                @"^\{\{speaker_(\d+)\}\}\s*:\s*(.+)$",
                RegexOptions.Singleline);
            if (!match.Success
                || !int.TryParse(match.Groups[1].Value, out int oneBasedSpeaker)
                || oneBasedSpeaker < 1
                || oneBasedSpeaker > SpeakerCount)
            {
                throw new AppException(
                    $"Paragraph {index + 1} must start with {{{{speaker_1}}}} through " +
                    $"{{{{speaker_{SpeakerCount}}}}} followed by a colon.");
            }
            result.Add(new OrchestratedScriptTurn(oneBasedSpeaker - 1, match.Groups[2].Value.Trim()));
        }
        if (result.Count == 0) throw new AppException("The orchestrated meeting script is empty.");
        return result;
    }

    public static readonly OrchestratedMeetingTemplate LaunchReadiness = new(
        "meeting-assistant-launch-readiness",
        "AI meeting assistant launch readiness",
        "4 speakers · expressive launch decision",
        ["Product Manager", "Engineering Lead", "Privacy & Security Lead", "Customer Success Lead"],
        ["male", "female", "male", "female"],
        """
        {{speaker_1}}: Alright, everyone's here — let's do this. I'm {{speaker_1}}, product manager for Decision Digest, and today we decide whether this thing actually ships. [exhales] I've rescheduled this meeting twice, so I'm not leaving without an answer. Quick reality check: the launch is five design partners, internal meetings only, post-meeting summaries with every line linked back to the transcript. Nothing auto-sends anywhere. That's the whole product. Where are we?

        {{speaker_2}}: I'm {{speaker_2}}, engineering lead, and the honest answer is "conditional go," which I realize is the least satisfying phrase in software. [laughs] The service is stable at pilot volume and the kill switch works — I tested it myself on Friday, and yes, it actually kills things. Two gates left: export events still don't show up reliably in the audit log, and the batching change needs forty-eight hours of clean canary. That's it. But I want those actually done, not "the PR is basically approved" done.

        {{speaker_3}}: I'm {{speaker_3}}, privacy and security. Conditional from me too, and my condition is NOT negotiable. [firm] If an attendee can't tell that processing is happening, we don't generate. Full stop. I also want one end-to-end deletion drill — a real participant request, all the way through to verified removal of the digest and the embeddings. Not a database command. A request.

        {{speaker_4}}: I'm {{speaker_4}}, customer success, and I bring good news for once! [cheerful] Customers love this thing. Pilot teams say it saves them ten, fifteen minutes per meeting. The bad news — [sighs] — is they keep calling the draft "the record." Which it is not. If we don't hammer "editable draft" into every screen and every training doc, someone is going to file an action item straight from a hallucination, and the escalation will have my name on it.

        {{speaker_1}}: [laughs] Noted. Okay, latency. Median is six seconds, but the tail reaches the high twenties. Do we need a week of shadowing, or is forty-eight hours enough? I want a number, not a vibe. And before anyone says "it depends"—

        {{speaker_2}}: [jumping in] —It depends. [laughs] Kidding! Forty-eight hours, if we define the evidence up front. Replay on ten thousand meetings already brought the ninety-fifth percentile under eleven seconds with no quality drop. Shadow traffic, one canary org, a rollback exercise, and if anything crosses a threshold, the clock resets. Adding five more days after clean evidence is just… superstition. [dry] Comforting, expensive superstition.

        {{speaker_3}}: Fine — but batching cannot cross region boundaries. If a latency win leaks a transcript out of region, I will personally pull the plug, and I will not be graceful about it. [half-joking]

        {{speaker_2}}: It can't. Batches form inside the org-and-region boundary, and there's an alert on any routing mismatch. You'd get paged before I do, which honestly seems fair.

        {{speaker_4}}: One operational thing — when the kill switch fires, the meetings stuck in the queue can't just say "processing" forever. Customers would rather see "delayed by your admin" than a spinner of lies.

        {{speaker_2}}: Agreed. There's a real "delayed" state, and support gets the exact state table before training. Screenshots and all.

        {{speaker_1}}: Okay, German. [sighs] Action-item recall is still a few points behind English. I say we keep it, label it beta, and gate it per language. Objections?

        {{speaker_4}}: Keep it — two of the five customers joined specifically for German. But the account team says "beta" out loud before enablement, and the weekly report breaks omissions out by language. No hiding it in a blended average.

        {{speaker_3}}: Agreed, as long as a German regression pauses German only. And on my deletion drill: support runs it while engineering watches. If the runbook needs an engineer at the keyboard, it failed. My no-go lines are written down — notice failure entering generation, derived content outliving its window, or transcript text showing up in audit logs.

        {{speaker_1}}: Then here's the decision: conditional go, five customers. {{speaker_2}} owns audit events and the canary. {{speaker_3}} owns notice and the deletion drill. {{speaker_4}} owns training and the escalation roster. Any function can pull the brake without a committee vote. [relieved] And can I just say — third attempt at scheduling this meeting, and we actually made a decision. I'm framing this calendar invite. Thanks, everyone.
        """);

    public static readonly OrchestratedMeetingTemplate ApiIncidentReview = new(
        "api-latency-incident-review",
        "API latency incident review",
        "3 speakers · expressive retrospective",
        ["Incident Commander", "Site Reliability Engineer", "Customer Support Lead"],
        ["male", "female", "male"],
        """
        {{speaker_1}}: I'm {{speaker_1}}, incident commander for yesterday's API latency mess. Blameless review, so nobody's getting fired — [wry] — though the config system is on thin ice. Timeline: nine forty-two a.m., checkout latency blows through the two-second objective. Mitigated at ten thirty-one, recovered at ten forty-seven. {{speaker_2}}, walk us through it.

        {{speaker_2}}: I'm {{speaker_2}}, the on-call SRE, running on four hours of sleep. [tired laugh] Nine thirty-eight: a routine config change raised the pricing service's connection pool limit. Fine in staging. In production, every instance opened connections at once and the database hit lock contention. And here's the fun part — [sarcastic] — every alert stayed GREEN. Meanwhile customers couldn't buy ANYTHING.

        {{speaker_3}}: I'm {{speaker_3}}, customer support lead, and customers noticed before our alerts did, which — [sighs] — is becoming a theme. First chat at nine forty-three: a retailer watching a checkout spinner for a full minute. By nine forty-seven, six reports across three queues — nobody saw the pattern until an agent posted them in one channel.

        {{speaker_1}}: Once the page finally fired, what made diagnosis so slow?

        {{speaker_2}}: [frustrated] The rollout dashboard said one hundred percent success — because technically the config did deploy successfully. [deadpan] Successfully broke everything. I wasted twenty minutes chasing the payment provider — slow-looking spans that were just queued behind our own thread pool. At ten oh-two I lined traces up against the deploy timeline — one relevant change all morning.

        {{speaker_3}}: Meanwhile agents called it "intermittent slowness" because some checkouts eventually finished. A forty-second checkout is not slow — it's a customer closing the tab. Severity should follow the user's task, not the HTTP status.

        {{speaker_1}}: Agreed. A two hundred that takes forty seconds is an outage wearing a disguise. So when did we finally—

        {{speaker_2}}: [jumping in] —Roll back? Ten oh-eight, after I reproduced the lock wait on a read replica. And then — [exasperated sigh] — seven minutes waiting for approval: the config owner wasn't in the channel and the runbook listed a team reorged away last year. Rollback ran ten fifteen to ten twenty-two. Latency dropped immediately.

        {{speaker_1}}: Seven minutes of a sev-one waiting for permission — that one's on me. Effective today, incident commanders can authorize rollback of reversible changes. {{speaker_3}}, communications?

        {{speaker_3}}: The status post went up at ten twelve, twenty-nine minutes in, saying we were "investigating elevated latency" — which, honestly, describes every day of my life. [dry] Customers wanted one answer: will retrying double-charge me? We couldn't say no until ten twenty. I want pre-approved language for delayed transactions and a dashboard my agents can actually read.

        {{speaker_2}}: The idempotency keys held — zero duplicates — but support shouldn't page me to learn that; I'll add a panel. Plus two fixes: a five-minute burn-rate alert on checkout latency — it would have fired at nine forty-one, before the first customer chat — and a ten-percent canary with an automatic halt.

        {{speaker_3}}: And I want ticket clustering — three enterprise customers, same symptom, ten minutes, flag it — even when filed under different categories. Plus a follow-up note to the forty-two affected accounts. Just those. Not a company-wide apology blast.

        {{speaker_1}}: Done. Owners: {{speaker_2}} — canary guard, lock-wait dashboard, burn alert, by Friday. Me — rollback authority and ownership audit by Wednesday. {{speaker_3}} — clustering and customer follow-up by Monday. The big lesson: measure availability at the checkout button, not the CPU graph. [warm] Nice recovery, both of you. Review goes out today.
        """);

    public static readonly OrchestratedMeetingTemplate PerformanceReviewOneOnOne = new(
        "performance-review-one-on-one",
        "Performance review 1:1",
        "2 speakers · candid feedback and growth",
        ["Engineering Manager", "Senior Software Engineer"],
        ["female", "male"],
        """
        {{speaker_1}}: Come in, sit down — and {{speaker_2}}, you can stop looking like you're walking into a root canal. [laughs] This is a good review. I'm {{speaker_1}}, your engineering manager, for the record. Short version first, because I know you hate suspense: strong year, exceeding expectations. The billing platform is more reliable because of you, and half the team asks "what would {{speaker_2}} do" during incidents, which is either a compliment or a cry for help.

        {{speaker_2}}: [relieved sigh] Okay. Wow. I'm {{speaker_2}}, senior engineer on billing — and yes, I was braced for the "growth areas" speech. Exceeding expectations feels… really good to hear, honestly. Especially since the ledger migration ran three weeks over and I've been quietly stewing about that since March.

        {{speaker_1}}: The migration going long is not the story. The story is you caught the retry bug that would have double-charged customers before it shipped. Reconciliation errors down sixty percent, and support got hours of their week back. [whispers] Nobody remembers a schedule slip. Everybody remembers double charges. The actual reservation from calibration was visibility — people outside our team sometimes learned about risks later than they needed to.

        {{speaker_2}}: [sighs] Yeah. That one's fair, and honestly I've heard it before. I hold updates until I actually understand the problem, because "something's wrong, more soon" feels like noise. During the database saturation thing I sat on the first update for an hour while I worked out whether it was traffic or the query plan… and meanwhile payments kept deploying straight into the blast radius. Point taken.

        {{speaker_1}}: It's not about broadcasting every theory. Four lines: what we know, what we don't, who's affected, when the next update comes. Your diagnosis was excellent — the silence around it was the problem. Now go ahead and ask the question you've been sitting on since you—

        {{speaker_2}}: [jumping in] Why not promotion? [laughs] Sorry. You clearly saw that coming. I led a cross-team migration, mentored two people through promo packets, and covered a staff gap for six months. I'm not angry, but… [frustrated] okay, I'm a little frustrated. What was missing?

        {{speaker_1}}: Completely fair question, and you deserve a real answer, not committee-speak. The gap is influence before execution. You aligned the database and billing teams after the design was mature — analytics and support found out late, and it cost us rework. At staff level you shape that stakeholder mess early and deliver through other people. Nobody doubts your judgment or your code. The question is whether the organization sees you leading beyond it.

        {{speaker_2}}: [reluctantly] That… lands. I kept pulling implementation back to myself because the schedule felt fragile, and handing someone an unclear problem felt like a trap. Which protected the launch and torpedoed the promo evidence at the same time. If the next project's definition of success is me personally closing the hardest tickets again, we've learned nothing.

        {{speaker_1}}: Which is exactly why I'm giving you account-event consolidation. Four teams, messy ownership, starts next month. You set the technical strategy, run the decision forum, and delegate the designs. I'll get the directors to sign a charter so you're not leading on vibes alone. [wry] And if I catch you writing half the implementation at two a.m., we're having a very different meeting.

        {{speaker_2}}: [laughs] Deal. But let's define success now: four teams aligned before implementation starts, each workstream with an owner who can defend the design without me in the room, and a weekly decision note people actually read. And midpoint feedback — I'm not waiting a year to find out I did it wrong again.

        {{speaker_1}}: Agreed on all of it. On money: the raise reflects the rating, final numbers next week. On promotion: show staff-level leverage through the midpoint and I'll take your case to the midyear window in May. I can't promise the outcome, but I promise you won't be guessing. And {{speaker_2}} — [warm] — genuinely well done this year. Now get out of my office before I start listing growth areas. [laughs]
        """);

    public static readonly IReadOnlyList<OrchestratedMeetingTemplate> All =
        [LaunchReadiness, ApiIncidentReview, PerformanceReviewOneOnOne];
}
