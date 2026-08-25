import Foundation

struct ExampleScenario: Identifiable {
    let id: String
    let title: String
    let excerpts: [ExampleExcerpt]
}

/// A role-specific script from a coordinated meeting scenario. Built-in
/// scripts are templates: `{{name}}` is resolved once when a user creates a
/// named copy, so playback and caching never depend on mutable profile data.
/// Scripts are written for ElevenLabs v3: bracketed audio tags such as
/// [laughs] or [sighs] steer the expressive delivery.
struct ExampleExcerpt: Identifiable {
    static let namePlaceholder = "{{name}}"

    let id: String
    let role: String
    let audience: String
    let meeting: String
    let text: String

    var menuTitle: String { "\(role) — \(meeting)" }
    var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }

    static let scenarios: [ExampleScenario] = [
        ExampleScenario(
            id: "q3-launch-retrospective",
            title: "Script templates",
            excerpts: [launchRetroProductManager, launchRetroEngineeringLead, launchRetroSupportLead]
        )
    ]

    static var all: [ExampleExcerpt] { scenarios.flatMap(\.excerpts) }

    static let launchRetroProductManager = ExampleExcerpt(
        id: "launch-retro-product-manager",
        role: "Product Manager",
        audience: "Engineering, design, marketing, and customer success",
        meeting: "Q3 launch retrospective",
        text: """
        Hey everyone — {{name}} here, product manager, and yes, I know, I promised this retro would be thirty minutes, so hold me to it. [laughs] Headline first: the launch shipped. On the third attempt, two weeks late, with a feature list that had been… let's say lovingly trimmed — but it shipped, and customers are actually using it. Adoption is at forty percent of the pilot group after ten days, which beats every internal bet, including mine.

        Now the uncomfortable part. [exhales] The two-week slip was not bad luck. It was me saying yes to three "tiny" scope additions in week two. Each one was reasonable. Together, they were a disaster. I have heard "it's just a checkbox" three times this quarter, and I now have a rule: nothing is ever just a checkbox. The pricing page rewrite alone touched ELEVEN screens. Eleven! [frustrated] And I found out live, in the review, along with everyone else. [sarcastic] Great way to learn about your own product.

        So here's what changes for Q4. Scope freezes on day one of the sprint — after that, new asks go to the backlog, no matter how small they look or how nicely marketing asks. [mischievously] And I say that with love, marketing. [whispers] Mostly. Second, the readiness checklist becomes a real gate, not a document we skim on launch morning. If support hasn't seen a feature, we are not launching it. Blindsiding our own support team twice a quarter is embarrassing and entirely fixable.

        And finally, the good stuff, because there was a lot of it. Engineering caught the billing edge case that would have mischarged annual plans. Design killed the onboarding step nobody needed. And the launch-day war room was — dare I say it — actually… calm. [pleased] Let's bottle that. Next launch: same energy, half the drama. That's my part — questions at the end.
        """
    )

    static let launchRetroEngineeringLead = ExampleExcerpt(
        id: "launch-retro-engineering-lead",
        role: "Engineering Lead",
        audience: "Product, engineering, and the on-call rotation",
        meeting: "Q3 launch retrospective",
        text: """
        {{name}} here, engineering lead, and let me address the elephant in the room right away: yes, the Friday deploy. [sighs] The one that took the search cluster down for forty minutes. I have relived it every day since, so let me save you the questions and just walk through it.

        Short version: we shipped an index migration at four thirty on a Friday, which, in hindsight, was a decision made by someone who has clearly never met a Friday. [laughs] The migration itself was correct. The rollout order was not. New code hit the old index for six minutes, queries failed, retries piled up, and the cluster tipped over in the most theatrical way possible.

        Here's what actually frustrates me, though. [frustrated] It's not the bug — bugs happen. It's that staging physically cannot reproduce this failure, because it runs one node and this was a coordination failure between five. We have said "staging isn't representative" in retros for a YEAR. A year! At some point that stops being an observation and starts being a choice. So we're choosing differently: staging gets a three-node cluster this sprint — it's already provisioned — and deploys freeze on Fridays after noon. Not a guideline. A freeze. [deadpan] The pipeline will literally refuse.

        Now the part that deserves applause. Detection to mitigation was nine minutes, nobody panicked, and the rollback runbook worked on the first try — which, if you've been here long enough… [whispers] you know is basically a miracle. [laughs] The on-call crew earned their weekend. Payments and identity were untouched, zero data loss, and the postmortem is linked in the channel. It's honest, occasionally funny, and names no one, because the system failed, not a person. Read it before Thursday. That's all from me.
        """
    )

    static let launchRetroSupportLead = ExampleExcerpt(
        id: "launch-retro-support-lead",
        role: "Customer Success Lead",
        audience: "Product, engineering, marketing, and support",
        meeting: "Q3 launch retrospective",
        text: """
        Hi all — {{name}}, customer success lead, bringing you the view from the other side of the launch. I'll be honest: I rehearsed a diplomatic version of this update and then deleted it. [laughs] You're getting the real one.

        First, the wins, because they are real. NPS from the pilot group is up nine points, three customers renewed early, and one of them named the new dashboard in their renewal call — unprompted! [excited] I nearly fell out of my chair. Do you know how rare unprompted praise is? Eight years in this job, and I can count those calls on one hand.

        Now. [exhales] The other side. Support tickets doubled in launch week — not because the product was broken, but because nobody told support it was coming. My team learned about the pricing change from a customer. From a CUSTOMER! [exasperated] Imagine explaining a price you have never seen, live, on a call, while smiling. That is a skill. My team has it. They should not need it.

        So I have one ask, and I am going to be annoyingly persistent about it: support sign-off joins the launch checklist. Forty-eight hours before ship, my team sees the feature, the pricing, and the FAQ. That's it. That's the whole ask. Two days. [pleading] I will bake cookies for whoever makes it happen.

        Beyond that, the feedback themes are genuinely encouraging. Customers describe the product as "finally getting out of my way," which is the nicest thing a user has ever said about us, and slightly backhanded, and I love it. [warm] Keep shipping like this — just, please, tell us first. That's my update. [whispers] The cookies are a real offer.
        """
    )
}
