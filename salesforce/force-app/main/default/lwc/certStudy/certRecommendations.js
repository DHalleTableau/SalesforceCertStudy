// "Suggest next certs": a simple, explainable recommender. No server call, no Trailhead data:
// it uses the certs the learner marked as earned, the area/type groupings in certCategories.js,
// prerequisites, and retirement status.
//
// Up to 3 picks come from the learner's own and related areas; up to 2 "broaden your skills"
// starting points are mixed in; any empty slots are filled by score.

import { certArea, certType } from './certCategories';

const LEVEL = {
    Foundations: 1,
    Administrator: 2,
    Specialist: 2,
    'Accredited Professional': 2,
    'Analyst / Designer': 3,
    Developer: 3,
    Consultant: 3,
    Architect: 4,
    Other: 3
};

// Areas that tend to go together (checked in both directions).
const RELATED = {
    'Data & Analytics': ['Platform', 'Integration', 'Agentforce & AI', 'Marketing'],
    'Sales & Service': ['Agentforce & AI', 'Commerce & Revenue', 'Industries', 'Platform'],
    Marketing: ['Data & Analytics', 'Commerce & Revenue', 'Sales & Service'],
    'Commerce & Revenue': ['Sales & Service', 'Platform', 'Marketing'],
    Industries: ['Sales & Service', 'Agentforce & AI', 'Platform'],
    Integration: ['Platform', 'Data & Analytics'],
    Slack: ['Platform', 'Agentforce & AI', 'Sales & Service'],
    'Agentforce & AI': ['Platform', 'Data & Analytics', 'Sales & Service', 'Slack'],
    Platform: ['Data & Analytics', 'Sales & Service', 'Integration', 'Slack', 'Agentforce & AI', 'Commerce & Revenue', 'Industries', 'Marketing']
};

// Popular starting points worth suggesting outside someone's current focus.
const STARTERS = [/Platform Administrator$/i, /Agentforce Specialist$/i, /Slack Administrator$/i];

const IN_AREA_SLOTS = 3;
const BROADEN_SLOTS = 2;

function isRelated(a, b) {
    return (RELATED[a] || []).includes(b) || (RELATED[b] || []).includes(a);
}

function short(name) {
    return name.replace(/^Salesforce (Certified|Accredited) /, '');
}

export function recommend(certs, earnedCodes, limit = 5) {
    const earnedSet = new Set(earnedCodes);
    const earned = certs.filter((c) => earnedSet.has(c.code));
    const earnedNames = new Set(earned.map((c) => c.name));

    const areaCount = {};
    const areaMaxLevel = {};
    const areaNames = {};
    earned.forEach((e) => {
        const a = certArea(e.name);
        areaCount[a] = (areaCount[a] || 0) + 1;
        areaMaxLevel[a] = Math.max(areaMaxLevel[a] || 0, LEVEL[certType(e.name)] || 3);
        (areaNames[a] = areaNames[a] || []).push(short(e.name));
    });
    const topEarnedArea = Object.keys(areaCount).sort((x, y) => areaCount[y] - areaCount[x])[0];

    const ranked = certs
        .filter(
            (c) =>
                !earnedSet.has(c.code) &&
                !c.isAggregate &&
                c.status !== 'Retiring' &&
                c.status !== 'Retired' &&
                (c.prereqs || []).every((p) => earnedNames.has(p))
        )
        .map((c) => {
            const area = certArea(c.name);
            const level = LEVEL[certType(c.name)] || 3;
            const same = areaCount[area] || 0;
            let related = 0;
            Object.keys(areaCount).forEach((a) => {
                if (a !== area && isRelated(area, a)) related += areaCount[a];
            });
            const starter = STARTERS.some((re) => re.test(c.name));

            let score = 0;
            let reason = '';
            if (same) {
                score += 3 + Math.min(same, 3);
                if (Math.abs(level - areaMaxLevel[area]) <= 1) score += 1;
                reason = `Builds on your ${area} certifications (${areaNames[area].slice(0, 2).join(', ')})`;
            } else if (related) {
                score += Math.min(related, 2) * 1.5;
                reason = `Related to your ${topEarnedArea} background`;
            }
            if (starter) {
                score += earned.length < 6 ? 2 : 1;
                if (!reason) reason = earned.length ? 'Popular starting point outside your current focus' : 'Popular place to start';
            }
            if (!earned.length && level === 1) score += 1; // foundations first for newcomers
            if (!reason) reason = 'Another area to explore';
            return { code: c.code, name: c.name, reason, score, level, inArea: same > 0 || related > 0, starter, same };
        })
        .sort((x, y) => y.score - x.score || x.level - y.level || x.name.localeCompare(y.name));

    const picked = [];
    const take = (list, n) => {
        list.forEach((x) => {
            if (n > 0 && picked.length < limit && !picked.includes(x)) {
                picked.push(x);
                n -= 1;
            }
        });
    };
    if (earned.length) take(ranked.filter((x) => x.inArea && !x.starter), IN_AREA_SLOTS);
    take(ranked.filter((x) => x.starter && !x.same), BROADEN_SLOTS);
    take(ranked, limit); // fill any remaining slots by score

    return picked.map((x) => ({
        code: x.code,
        name: x.name,
        reason: x.reason,
        kind: x.starter && !x.same ? 'broaden' : 'area'
    }));
}
