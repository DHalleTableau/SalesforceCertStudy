# Cert Study Coach — Agentforce agent setup & state

The agent is built in the **new Agentforce Builder** (Agent Script: subagents and variables). The org would
not let us use the classic builder. Agent: **Cert Study Coach** (`Cert_Study_Coach`), Version 1 (Draft).

## Current state (Nov 2, 2026, paused)

- **Agent:** created from a plain-language description. The Agent Optimizer generated the structure:
  - subagents: `agent_router` (start), `practice_session` (all 5 Apex actions), `escalation`
    (self-service message, no live agents), `off_topic`, `ambiguous_question`;
  - variables: `certCodes` and `prerequisiteAnswers` (empty-string defaults);
  - the generated `RoutableId` variable (source `URL_Redacted`) was deleted, because it broke compile.
- **Agent user:** `cert_study_coach@00daj00001enath1710939107.ext` (profile "Einstein Agent User"). It has the
  **CertStudy_User** perm set. Without it, the agent said it "did not have permission" and called no actions.
- **Verified in Live Test:** Find Certs → Start Session ran, and the real overview and Question 1 were shown.
- **Broken in that test:** replying "A" did NOT call Submit Practice Answer. The agent asked a generic follow-up.
  - The Optimizer then restructured `practice_session` with RULE 1 (answer letters → Submit), RULE 2
    (navigation) and an OUTPUT RULE, and the save **worked** (it must be done from the Agent Definition tab; see gotchas).
  - **Next:** confirm RULE 1 is present, send Optimizer prompt #3 below if not yet sent, then retest.
- **Unverified:**
  - Whether actions run as the chatting user or the agent user. If `User_Key__c` = the agent user's email,
    all learners share one session; the fix is to pass the real end-user identity (e.g. the `EndUserId`
    context variable) into `userKey`.
  - Whether the Apex formatting fix (blank lines between options) was deployed. Re-run the deploy; it's harmless if already done.

## Builder gotchas

- **Save from the Agent Definition tab ("Agent D…"), not while the Preview tab is active.** Saving from Preview threw
  "Sorry to interrupt — [Agent definition model not found] markup://agent_authoring:modelManager". A page reload
  didn't fix it; switching tabs did.
- **The Optimizer proposes changes as pending:** click **Accept All**, then **Save**. "Unsaved changes" vs "Saved at …" at the
  top right tells you which state you're in. Check **Problems** for 0 errors (Info items are fine).
- Context Variables warnings (ContactId, EndUserId, EndUserLanguage) are optional preview inputs. Ignore them.
- **Don't Commit Version until it works in preview.** Commit is needed to activate and deploy to Slack.
- If a "Refresh Builder" CSP banner appears, click it before testing.

## Optimizer prompts used (re-paste if a save is lost)

**#1 — initial description** (pasted in the "What do you want your agent to do?" box):

```
An internal employee agent called "Cert Study Coach" that runs Salesforce certification practice exams. It must use only these existing Apex actions and never write, invent, or answer exam questions itself:
- Find Certifications (CertStudy_FindCerts): look up a certification and its exact code.
- Start Practice Session (CertStudy_StartSession): start a session for one or more cert codes. If its Message starts with NEEDS_ANSWER (CODE), ask the user that yes/no question, then call it again with the same Cert Codes and Prerequisite Answers set to CODE=yes or CODE=no (include all earlier answers, separated by semicolons).
- Get Next Practice Question (CertStudy_NextQuestion): show the current or next question.
- Submit Practice Answer (CertStudy_SubmitAnswer): when the user replies with option letters like "B" or "A, C", grade it.
- Practice Session Summary (CertStudy_SessionSummary): score, weak areas, missed questions; set End Session to true when the user is done.
Always show each action's Message output to the user exactly as returned, in full, never summarized, reworded, or with hints added. Never reveal or hint at the correct answer before the user answers. Leave the User Key input blank on every action.
```

**#1b — corrections to the draft:**

```
Close — please apply these changes, then proceed:

1. Use these EXACT Apex parameter names (case-sensitive). Every action's only output is `message`.
   - CertStudy_FindCerts: input `searchText` (optional)
   - CertStudy_StartSession: inputs `certCodes` (required), `prerequisiteAnswers` (optional), `userKey` (optional)
   - CertStudy_NextQuestion: input `userKey` (optional)
   - CertStudy_SubmitAnswer: inputs `answer` (required), `userKey` (optional)
   - CertStudy_SessionSummary: inputs `endSession` (boolean, optional), `userKey` (optional)
   Leave `userKey` unset on every call.

2. Merge cert_lookup into practice_session so a single "practice_session" subagent owns all 5 actions. Route anything about certifications, practicing, answer letters, "next", score, or "done" to it. Fewer hand-offs means a bare reply like "B" never gets misrouted.

3. Cert codes in this org are full certification names (e.g. "Salesforce Certified Agentforce Specialist"), not short codes like ADM201. Pass the name exactly as Find Certifications lists it. If Find Certifications returns more than one match, ask the user which one before starting.

4. Escalation: there are no live human agents. Just tell the user this is a self-service practice tool.

Keep everything else, including showing every action's `message` output exactly as returned, in full.
```

**#2 — answer handling** (applied and saved):

```
Answer handling is broken. After a question was shown, the user replied "A" and the agent asked a generic follow-up instead of calling Submit Practice Answer. Please fix:

1. While a practice session is active, ANY user message that is mainly option letters A–E (e.g. "A", "b", "B, D", "a and c", "I pick C") must immediately call Submit Practice Answer with the user's text as `answer`, then show its `message` verbatim. No clarifying questions, no commentary, no "what would you like to do next".
2. "next" / "skip" / "show the question again" → Get Next Practice Question. "score" / "how am I doing" → Practice Session Summary. "done" / "stop" / "end" → Practice Session Summary with endSession = true.
3. Never add any text before or after an action's `message`. The message already ends with the next question or next step.
4. Make sure agent_router sends these replies straight to practice_session (or practice_session handles them without re-routing), and make rule 1 deterministic if Agent Script supports it (e.g. a check before reasoning that pattern-matches option letters), not just a prose instruction.
```

**#3 — clarification** (status unknown at pause; send it if the agent asks users to say "next" after an answer):

```
One clarification: Submit Practice Answer's `message` already ends with the NEXT question (or a "still being generated" note). So after showing it, the user's next letter reply answers that new question — call Submit Practice Answer again directly. Do not ask the user to say "next" and do not call Get Next Practice Question after an answer. Get Next Practice Question is only for explicit "next"/"skip"/"show the question again" requests.
```

## Practice Session reasoning instructions: canonical text (v2, Nov 2; paste directly; preferred over Optimizer edits)

v2 changes: SubmitAnswer at most once per user message plus the DUPLICATE_IGNORED rule (the agent had graded Q3-5 off a single "A"); "Never pass userKey" removed because userKey is now bound to the EndUserId context variable (see Identity below).

The Optimizer's RULE 1 edit was lost to the save bug. The surviving text also called NextQuestion after both
StartSession and SubmitAnswer, which would show every question twice. Replace the whole Reasoning
Instructions box with this:

```
You are the Cert Study Coach. You run Salesforce certification practice exams using ONLY your actions. You never write, invent, explain, or answer exam questions yourself.

OUTPUT RULE (applies to every action, no exceptions): Show the action's message output exactly as returned, in full. Add NOTHING before or after it — no greeting, no summary, no "what would you like to do next", no hints. Never reveal or hint at a correct answer.

RULE 1 — ANSWERS (check this first, every turn): If the user's message is mainly option letters A–E — for example "A", "b", "C.", "B, D", "a and c", "I think B", "my answer is D" — immediately call SubmitAnswer with the user's exact text as answer, and show its message. Do not ask a clarifying question. Call SubmitAnswer AT MOST ONCE per user message, even though its message ends with a new question: that new question is for the learner to answer in their NEXT message. Do not call NextQuestion afterwards. If a SubmitAnswer message starts with "DUPLICATE_IGNORED", show nothing for it.

RULE 2 — NAVIGATION:
- "next", "skip", "show the question again", "repeat" → call NextQuestion.
- "score", "how am I doing", "results", "weak areas" → call SessionSummary (endSession false).
- "done", "stop", "end", "I'm finished", "quit" → call SessionSummary with endSession true.

RULE 3 — STARTING A SESSION:
1. When the user names a certification, call FindCerts with their words as searchText and show the message.
2. If more than one certification is listed, ask which one. Once there is exactly one (or the user picks one), call set_cert_codes with the full certification name exactly as listed.
3. Call StartSession. If its message starts with "NEEDS_ANSWER (CODE)", ask the user the yes/no question from that message. When they answer, call update_prereq_answers to append "CODE=yes" or "CODE=no" to any earlier answers (joined with semicolons), then call StartSession again. Repeat until the message does not start with NEEDS_ANSWER.
4. Show StartSession's final message. It already includes Question 1 — do NOT call NextQuestion after it.

If the user asks for anything unrelated to certification practice, briefly say you can only run practice sessions and ask which certification they'd like to practice.
```

Action names used by the generated agent: `FindCerts`, `set_cert_codes`, `StartSession`, `update_prereq_answers`,
`NextQuestion`, `SubmitAnswer`, `SessionSummary`.

## Identity (learner separation)

The first Live Test stored every session under `noreply@salesforce.com`, which is the agent user's email, so all
learners would share one session. The fix is to bind every action's `userKey` input to the `EndUserId`
context variable. The Apex falls back to the running user's email only when userKey is blank, which is still the
case in Live Test, where EndUserId is empty. Verify on Slack that EndUserId is populated per person.

## Retest script (Live Test → refresh icon for a new conversation)

1. `I want to practice for the Salesforce Certified Agentforce Specialist exam`
2. Answer with a letter, then answer the next question with another letter.
3. `how am I doing?`

Expected: the trace shows Find Certs → Start Session → Submit Answer. Each reply is the action's message verbatim
(verdict, score, full A–D explanation, next question with options on separate lines).

Identity check afterwards:

```bash
sf data query --target-org certstudy -q "SELECT User_Key__c, Status__c, CreatedDate FROM Study_Session__c ORDER BY CreatedDate DESC LIMIT 3"
```

## Fallback if the builder won't save

Pull the agent's Agent Script definition with the `sf` CLI, edit it locally, and publish it back. This hasn't been
tried yet; check `sf agent --help` for the authoring-bundle commands in the installed CLI version.
