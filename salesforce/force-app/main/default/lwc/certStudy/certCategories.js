// Derives a "type" and a "product area" from a certification's name, for picker filters.
// Rules are checked in order and the first match wins; anything unmatched is "Other".
// Heuristic only: if a cert lands in the wrong bucket, adjust the rules here.

export const ALL = 'All';

const TYPE_RULES = [
    ['Accredited Professional', /accredited/i],
    ['Architect', /architect/i],
    ['Administrator', /administrator/i],
    ['Developer', /developer|app builder/i],
    ['Consultant', /consultant/i],
    ['Specialist', /specialist/i],
    ['Foundations', /foundations/i],
    ['Analyst / Designer', /business analyst|data analyst|designer|strategist/i]
];

const AREA_RULES = [
    ['Slack', /slack/i],
    ['Data & Analytics', /tableau|crm analytics|einstein discovery|data 360|data cloud/i],
    ['Integration', /mulesoft/i],
    ['Marketing', /marketing cloud/i],
    ['Commerce & Revenue', /commerce|b2b|b2c|order management|cpq|revenue/i],
    [
        'Industries',
        /industries|energy|utilities|net zero|nonprofit|education|health|life sciences|financial services|communications|public sector|manufacturing|consumer goods|trade promotion|loyalty|media cloud/i
    ],
    // Word boundaries: plain /sales/ would also match "Salesforce".
    ['Sales & Service', /\bsales\b|\bservice\b|contact center|field service/i],
    ['Agentforce & AI', /agentforce/i],
    [
        'Platform',
        /platform|application architect|system architect|technical architect|heroku|javascript|omnistudio|business analyst|experience cloud|process automation/i
    ]
];

function firstMatch(rules, name) {
    const hit = rules.find(([, re]) => re.test(name || ''));
    return hit ? hit[0] : 'Other';
}

export function certType(name) {
    return firstMatch(TYPE_RULES, name);
}

export function certArea(name) {
    return firstMatch(AREA_RULES, name);
}

export function typeOptions() {
    return [ALL, ...TYPE_RULES.map((r) => r[0]), 'Other'].map((v) => ({ label: v, value: v }));
}

export function areaOptions() {
    return [ALL, ...AREA_RULES.map((r) => r[0]), 'Other'].map((v) => ({ label: v, value: v }));
}
