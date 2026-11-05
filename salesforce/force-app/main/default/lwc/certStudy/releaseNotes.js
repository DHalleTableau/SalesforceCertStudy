// "What's new" release log, newest first. Add an entry whenever APP_VERSION in certStudy.js is bumped.
// Keep items short and learner-facing (what changed for them, not how it was built).

// "Coming soon" list shown above the release log. No versions or dates on purpose.
// Learner-facing only; remove an item when it ships (and add it to RELEASES).
export const UPCOMING = [
    'A personal stats dashboard: your scores over time, by certification and section, and how close you are to passing.',
    'Updates on problems you report and resources you share, so you know when they have been reviewed or fixed.',
    'Non-Salesforce certifications, starting with AI certifications that are useful at work.',
    'Logging in with Salesforce single sign-on, instead of waiting for an email code.'
];

export const RELEASES = [
    {
        version: 'v0.12.0',
        date: 'Nov 5, 2026',
        items: [
            'Share a study resource: send a link or notes for any certification. Approved resources help write new questions.',
            'Suggest an improvement: tell us what would make Cert Study better.',
            'What\'s new: this page, so you can see what changed in each version and what is coming soon.',
            'Clearer login page: it now explains how to sign up and how to log in with an email code.',
            'Keep studying on Trailhead: official Trailhead prep links after every practice session and test, with links for your weakest sections first. My progress keeps a running list of every link suggested to you.'
        ]
    },
    {
        version: 'v0.11.0',
        date: 'Nov 5, 2026',
        items: [
            'Report a problem with any question (inaccurate, more than one right answer, outdated, unclear, and more), right from the question or its explanation.'
        ]
    },
    {
        version: 'v0.10.0',
        date: 'Nov 4, 2026',
        items: [
            'Retiring exams are labeled with their retirement date and what to take instead, with an option to hide them.',
            'Filter certifications by product area and type.',
            'Prerequisites are shown next to each certification.',
            'Mark certifications you already hold as earned, and hide them from the list.',
            'Suggest next certs: up to five recommendations based on what you have earned.'
        ]
    },
    {
        version: 'v0.9.0',
        date: 'Nov 3, 2026',
        items: [
            'New look: Salesforce-branded banner, version number and contact details.',
            'More reliable question generation when many people practice at once.',
            'A clearer message when you try to log in before signing up.'
        ]
    },
    {
        version: 'v0.8 and earlier',
        date: 'Nov 2, 2026',
        items: [
            'Pilot launch on Experience Cloud: sign up with your @salesforce.com email and log in with an emailed code.',
            'Practice mode with explanations for every option, timed mock tests scored by exam section, and My progress.'
        ]
    }
];
