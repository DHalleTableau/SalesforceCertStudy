"""Aggregate/prerequisite resolution for session setup.

See PLAN.md's Locked-in decisions, "Aggregate vs. prerequisite
session-setup behavior":
- An aggregate cert has no exam of its own -- its full prerequisite
  tree is included automatically, with no prompt.
- A non-aggregate cert with 1+ direct prerequisites needs a yes/no
  answer before its prerequisites are included. This applies at every
  non-aggregate level walked (including the certs the user directly
  selected), not just the top level.
- Descent continues silently through aggregate nodes; through
  non-aggregate nodes only after their prompt is answered "yes".

This is a pure function against the DB (no Flask) so it can pause and
resume across requests: the caller collects one prompt answer per
call and re-invokes with the accumulated answers until resolution
completes with no pending prompt.
"""


def resolve_certs(selected_cert_codes, answered_prompts=None):
    """Resolve a session's full cert_codes set from what the user
    selected, walking CertPrerequisite edges breadth-first.

    Args:
      selected_cert_codes: certs the user directly picked.
      answered_prompts: {cert_code: bool} -- answers already collected
        for non-aggregate certs with prerequisites ("yes, include
        this cert's prerequisites" / "no, don't"). None/omitted keys
        are treated as not-yet-answered.

    Returns {"resolved": sorted list of cert_codes, "pending_prompt":
    cert_code or None}. If pending_prompt is set, resolution paused --
    the caller should ask the user "Also include <cert>'s
    prerequisites?", add the answer to answered_prompts under that
    cert_code, and call again. Must be called inside a Flask app
    context.
    """
    from models import Cert, CertPrerequisite

    answered_prompts = answered_prompts or {}
    resolved = set(selected_cert_codes)
    to_process = list(selected_cert_codes)
    processed = set()

    while to_process:
        cert_code = to_process.pop(0)
        if cert_code in processed:
            continue
        processed.add(cert_code)

        prereq_edges = CertPrerequisite.query.filter_by(cert_code=cert_code).all()
        if not prereq_edges:
            continue

        cert = Cert.query.get(cert_code)
        is_aggregate = bool(cert and cert.is_aggregate)

        if not is_aggregate:
            answer = answered_prompts.get(cert_code)
            if answer is None:
                return {"resolved": sorted(resolved), "pending_prompt": cert_code}
            if not answer:
                continue  # user said no -- don't pull in these prerequisites

        for edge in prereq_edges:
            prereq_code = edge.prereq_cert_code
            resolved.add(prereq_code)
            if prereq_code not in processed:
                to_process.append(prereq_code)

    return {"resolved": sorted(resolved), "pending_prompt": None}
