"""LLM gateway wrapper for question generation and cert-overview
derivation, plus grounding-excerpt assembly for both.

Only worker.py calls into this module -- app.py (the web process) never
calls the model in a request; see PLAN.md's Architecture Overview.

The org's Claude access is internal-only (a hard requirement, not a
preference -- PLAN.md's Locked-in decisions) and goes through an
internal gateway that turned out to be a unified multi-provider proxy
speaking the OpenAI Chat Completions API for every model (Claude, GPT,
Gemini all listed as "owned_by": "openai" on the gateway's /v1/models
endpoint) -- NOT Anthropic's native Messages API, even for Claude
models. So this uses the `openai` package pointed at that gateway,
with OpenAI-style function-calling for structured output, rather than
the `anthropic` package. Confirmed working against a real request.
"""
import os

MODEL = os.environ.get("CLAUDE_MODEL", "claude-sonnet-5")


def assemble_grounding_text(cert_code, max_chars=12000):
    """Build the grounding text passed to the model for a given cert.

    Primary (Base) resources are listed first, labeled PRIMARY SOURCE;
    additional resources follow, labeled ADDITIONAL SOURCE -- this is
    how "primary sources are weighted most heavily" (PLAN.md) is
    actually implemented: ordering + labeling, trusting the model to
    follow the label, rather than a numeric weighting scheme.

    For each resource, prefers `pasted_text` over `fetched_text`: per
    PLAN.md's Phase 2 finding, Tier-1 auto-fetch essentially never
    produces usable content for this app's real sources (JS-rendered
    Salesforce Help pages), so pasted_text is the content that
    actually matters in practice. Resources with neither are skipped.

    Truncates to max_chars total (primary content is assembled first,
    so it's the last thing cut if truncation kicks in).

    Must be called inside a Flask app context. Returns "" if the cert
    has no usable grounding content at all -- callers should treat
    that as "can't generate a question for this cert yet."
    """
    from models import Resource

    resources = Resource.query.filter_by(cert_code=cert_code).all()
    resources.sort(key=lambda r: 0 if r.role == "primary" else 1)

    sections = []
    for resource in resources:
        content = resource.pasted_text or resource.fetched_text
        if not content:
            continue
        label = "PRIMARY SOURCE" if resource.role == "primary" else "ADDITIONAL SOURCE"
        sections.append(f"=== {label}: {resource.url} ===\n{content.strip()}")

    return "\n\n".join(sections)[:max_chars]


def _build_client():
    """Construct the OpenAI-compatible client pointed at the internal
    gateway (ANTHROPIC_AUTH_TOKEN as the bearer token / api_key,
    ANTHROPIC_BASE_URL as the gateway URL -- names kept matching the
    org's Claude Code setup docs even though the wire protocol turned
    out to be OpenAI-shaped, not Anthropic's). SALESFORCE_CA_BUNDLE
    points at a PEM file of the org's internal certificate authorities
    (export via `security find-certificate -a -p
    /Library/Keychains/System.keychain` on a corporate-managed Mac) so
    TLS trusts the internal gateway's certificate.
    """
    import httpx
    from openai import OpenAI

    ca_bundle = os.environ.get("SALESFORCE_CA_BUNDLE")
    http_client = httpx.Client(verify=ca_bundle) if ca_bundle else None

    return OpenAI(
        api_key=os.environ["ANTHROPIC_AUTH_TOKEN"],
        base_url=os.environ["ANTHROPIC_BASE_URL"],
        http_client=http_client,
    )


def _generate_question_tool(format):
    """Build the submit_question tool schema for a specific format.

    minItems/maxItems are set structurally per format (4 options/1
    correct for single, 5 options/2-3 correct for multi) rather than
    relying on prose alone in the prompt -- a real failure seen without
    this: a multi-select request came back with 24 options. A single
    fixed schema can't express "4 if single, 5 if multi", so this
    builds the right one per call instead.

    Uses two parallel flat arrays (option_keys, option_texts) instead
    of one array of {key, text} objects -- another real failure seen:
    this gateway/model combination occasionally corrupts a nested
    array-of-objects (leaking raw tool-call-formatting text into it
    instead of proper JSON), but is much more reliable with flat
    arrays of plain strings. generate_question() zips these back into
    the [{"key", "text"}, ...] shape the rest of the app expects.
    """
    num_options = 4 if format == "single" else 5
    min_correct, max_correct = (1, 1) if format == "single" else (2, 3)
    return {
        "type": "function",
        "function": {
            "name": "submit_question",
            "description": (
                "Submit one practice exam question with full-detail feedback."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "stem": {
                        "type": "string",
                        "description": "The question text presented to the user.",
                    },
                    "option_keys": {
                        "type": "array",
                        "description": (
                            f"Exactly {num_options} option letters, e.g. "
                            f'["A", "B", "C", "D"].'
                        ),
                        "minItems": num_options,
                        "maxItems": num_options,
                        "items": {"type": "string"},
                    },
                    "option_texts": {
                        "type": "array",
                        "description": (
                            f"Exactly {num_options} answer option texts, in "
                            "the same order as option_keys."
                        ),
                        "minItems": num_options,
                        "maxItems": num_options,
                        "items": {"type": "string"},
                    },
                    "correct": {
                        "type": "array",
                        "description": (
                            f"The key(s) of the correct option(s): exactly "
                            f"{min_correct} key(s)."
                            if min_correct == max_correct
                            else (
                                f"The key(s) of the correct option(s): "
                                f"{min_correct}-{max_correct} keys."
                            )
                        ),
                        "minItems": min_correct,
                        "maxItems": max_correct,
                        "items": {"type": "string"},
                    },
                    "feedback_md": {
                        "type": "string",
                        "description": (
                            "Long-form feedback: why the correct answer(s) are "
                            "correct, AND a separate explanation for each wrong "
                            "option covering specifically why it is wrong. Should "
                            "be thorough and terminology-focused, not a brief "
                            "summary -- this is shown to the user after they "
                            "answer, not truncated or shortened."
                        ),
                    },
                },
                "required": [
                    "stem",
                    "option_keys",
                    "option_texts",
                    "correct",
                    "feedback_md",
                ],
            },
        },
    }


def generate_question(
    cert_name, domain, difficulty, format, grounding_text, avoid_stems=None
):
    """Generate one practice question + full-detail feedback via the model.

    Args:
      cert_name: display name of the certification, e.g.
        "Salesforce Certified Agentforce Specialist".
      domain: the exam domain/category to target (weak-area targeting
        picks this; may be None to let the model choose from grounding_text).
      difficulty: 1 (easiest) to 5 (hardest) -- ramps up over a session.
      format: "single" (1 correct of 4 options) or "multi" (2-3 correct
        of 5 options, graded all-or-nothing).
      grounding_text: excerpts from the cert's Exam Guide resources
        (primary-weighted) to ground the question in real exam content.
      avoid_stems: stems already generated for this cert in this
        session (any status), so repeated calls with identical
        grounding_text don't converge on the same "most obvious"
        question every time.

    Returns a dict with keys: stem, options (list of {key, text}),
    correct (list of option keys), feedback_md, plus the format and
    difficulty passed in (echoed back so the caller doesn't have to
    track them separately when building a QuestionQueueItem).
    """
    import json

    client = _build_client()

    format_instruction = (
        "This must be a SINGLE-select question: EXACTLY 4 options, "
        "EXACTLY 1 correct answer. Not 3, not 5 -- exactly 4 options."
        if format == "single"
        else "This must be a MULTI-select question: EXACTLY 5 options, "
        "EXACTLY 2 or 3 correct answers (graded all-or-nothing). Not 4, "
        "not 6 -- exactly 5 options."
    )

    domain_instruction = (
        f"Focus specifically on the domain/category: {domain}."
        if domain
        else "Choose an appropriate domain from the grounding content below."
    )

    avoid_instruction = ""
    if avoid_stems:
        stem_list = "\n".join(f"- {s}" for s in avoid_stems)
        avoid_instruction = f"""
Already asked in this session -- cover a DIFFERENT aspect, term, or scenario, not a rephrasing of any of these:
{stem_list}
"""

    prompt = f"""You are writing one practice exam question for the Salesforce certification "{cert_name}".

{format_instruction}
{domain_instruction}
Difficulty: {difficulty}/5 (1 = foundational recall, 5 = nuanced/scenario-based).
Emphasize terminology precision -- the user has identified terminology as their weakest area.
{avoid_instruction}
Ground the question in this exam content (do not invent facts outside it):
---
{grounding_text}
---

Call submit_question with the question. feedback_md must be long-form: explain why the correct answer(s) are correct, AND give a separate explanation for why EACH wrong option is wrong. Do not write a short summary -- this is the full explanation shown to the user."""

    response = client.chat.completions.create(
        model=MODEL,
        max_tokens=4096,
        tools=[_generate_question_tool(format)],
        tool_choice={"type": "function", "function": {"name": "submit_question"}},
        messages=[{"role": "user", "content": prompt}],
    )

    call = response.choices[0].message.tool_calls[0]
    parsed = json.loads(call.function.arguments)

    # Tool-call arguments occasionally come back missing a field
    # entirely, or corrupted, on this gateway/model combination -- use
    # .get()/zip defensively so a malformed response fails validation
    # in worker.py's _is_valid_question (and gets retried) instead of
    # crashing the caller. option_keys/option_texts are expected to be
    # lists (see _generate_question_tool's flat-array rationale); if
    # either isn't, treat it as empty so the resulting option count
    # mismatch trips validation cleanly.
    option_keys = parsed.get("option_keys")
    option_texts = parsed.get("option_texts")
    if not isinstance(option_keys, list) or not isinstance(option_texts, list):
        option_keys, option_texts = [], []
    options = [
        {"key": k, "text": t} for k, t in zip(option_keys, option_texts)
    ]

    result = {
        "stem": parsed.get("stem", ""),
        "options": options,
        "correct": parsed.get("correct", []) if isinstance(parsed.get("correct"), list) else [],
        "feedback_md": _strip_tool_call_artifacts(parsed.get("feedback_md", "")),
        "format": format,
        "difficulty": difficulty,
    }
    return result


_ARTIFACT_MARKERS = (
    "</feedback_md>",
    "</invoke>",
    "<parameter",
    "</parameter>",
    "<function_calls>",
    "</function_calls>",
    "<invoke",
)


def _strip_tool_call_artifacts(text):
    """Long free-text fields occasionally get stray tool-call-formatting
    tokens leaked onto the end (a quirk of this gateway/model
    combination -- seen on feedback_md, which is the longest field).
    Truncate at the first occurrence of any known marker.
    """
    earliest = len(text)
    for marker in _ARTIFACT_MARKERS:
        idx = text.find(marker)
        if idx != -1:
            earliest = min(earliest, idx)
    return text[:earliest].rstrip()


_DERIVE_OVERVIEW_TOOL = {
    "type": "function",
    "function": {
        "name": "submit_cert_overview",
        "description": (
            "Submit derived overview metadata for a certification exam "
            "based on its exam guide text."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "duration_min": {
                    "type": "integer",
                    "description": "Exam duration in minutes.",
                },
                "num_questions": {
                    "type": "integer",
                    "description": "Number of questions on the exam.",
                },
                "passing_score": {
                    "type": "integer",
                    "description": "Passing score as a percentage, e.g. 68.",
                },
                "domains": {
                    "type": "array",
                    "description": (
                        "Exam domains/categories and their weight "
                        "percentages, which should sum to ~100."
                    ),
                    "items": {
                        "type": "object",
                        "properties": {
                            "name": {"type": "string"},
                            "weight_pct": {"type": "number"},
                        },
                        "required": ["name", "weight_pct"],
                    },
                },
            },
            "required": [
                "duration_min",
                "num_questions",
                "passing_score",
                "domains",
            ],
        },
    },
}


def derive_cert_overview(cert_name, primary_text):
    """Derive cert overview metadata from a cert's primary Exam Guide
    text via the model: duration, # questions, passing score, and
    domain/category weightings.

    Called once per cert on first session start (see PLAN.md's Cert
    Overview Derivation) and cached on the Cert row rather than
    re-derived every session.

    Returns a dict: {duration_min, num_questions, passing_score,
    domains_json} -- domains_json is a list of {name, weight_pct}
    dicts, matching Cert's domains_json column directly.
    """
    import json

    client = _build_client()

    prompt = f"""Extract the exam overview details for the Salesforce certification "{cert_name}" from its exam guide text below.

Exam guide text:
---
{primary_text}
---

Call submit_cert_overview with the exam duration in minutes, number of questions, passing score (as a percentage), and the list of exam domains/categories with their weight percentages (should sum to approximately 100). Use the numbers actually stated in the text; only estimate if a field genuinely isn't stated."""

    response = client.chat.completions.create(
        model=MODEL,
        max_tokens=2048,
        tools=[_DERIVE_OVERVIEW_TOOL],
        tool_choice={"type": "function", "function": {"name": "submit_cert_overview"}},
        messages=[{"role": "user", "content": prompt}],
    )

    call = response.choices[0].message.tool_calls[0]
    parsed = json.loads(call.function.arguments)
    return {
        "duration_min": parsed["duration_min"],
        "num_questions": parsed["num_questions"],
        "passing_score": parsed["passing_score"],
        "domains_json": parsed["domains"],
    }
