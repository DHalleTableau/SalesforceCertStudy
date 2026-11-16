// "What's new" release log, newest first. Add an entry whenever APP_VERSION in certStudy.js is bumped.
// Keep items short and learner-facing (what changed for them, not how it was built).

// "Coming soon" list shown above the release log. No versions or dates on purpose.
// Learner-facing only; remove an item when it ships (and add it to RELEASES).
export const UPCOMING = [
    'More licensing and formula questions: edition and plan comparison scenarios (which plan solves which problem) and formula and filter logic, for the certifications where they show up on the exam.',
    'Study reminders: get an email (Slack later) on a schedule you choose, with more reminders as your exam date gets closer and a sample question from your weakest sections.',
    'Practice in Slack: run a practice session for one certification right inside Slack.',
    'Score trends across attempts: if you take an exam more than once, see how each section changed from one attempt to the next.',
    'A personal stats dashboard: your scores over time, by certification and section, and how close you are to passing.',
    'Non-Salesforce certifications, starting with AI certifications that are useful at work.',
    'Logging in with Salesforce single sign-on, instead of waiting for an email code.'
];

export const RELEASES = [
    {
        version: 'v0.14.2',
        date: 'Nov 16, 2026',
        items: [
            'Exam-matched question formats: new questions now use the answer formats of each real exam, such as pick one of three, pick one of four, or pick two or three. Your existing question pool turns over gradually.',
            'Mock tests are closer to the real thing: they now include 5 extra questions that do not count toward your score (for example 65 questions, 60 scored). You are not told which ones, and every miss still shows in your review.'
        ]
    },
    {
        version: 'v0.14.1',
        date: 'Nov 16, 2026',
        items: [
            'Exam results: the paste box is much taller, so you can see everything you pasted, and it shows how many lines it found.',
            'My exams: the exam pickers now have a search box. Type part of a name or code to find a certification.'
        ]
    },
    {
        version: 'v0.14.0',
        date: 'Nov 13, 2026',
        items: [
            'Study on the go: Cert Study works in your phone\'s browser. Start a session on your laptop and pick it up where you left off on your phone, or the other way around.',
            'Minimum difficulty for practice: choose a level from 1 to 5 and only get questions at that level or harder.',
            'Focus on my weaker sections: for certifications you have practiced or tested before, get more practice questions from the sections you scored lowest in. Practice only, never in tests.',
            'Quick select: a Deselect all button, and Select last session to reselect the certifications from your most recent practice or test.',
            'Upcoming exams: add the certifications you are studying for, with an optional exam date, then use Select upcoming exams to pick them in one click. After your exam date we ask whether you passed.',
            'Exam results: if you did not pass, paste in your section-level scores, check how each line maps to a section, and practice focuses on the sections below the pass mark until you pass. Sections you passed still come up, about half as often.',
            'My exams: completed exams (passed or not) stay on file. Tick Show completed exams to see them, and add or update the section scores for an exam you did not pass at any time, delete a completed record, or add an earlier attempt (such as a past failure) with its date and scores.',
            'Your selections are now kept when you open What\'s new or send a suggestion, then come back.',
            'Retiring exams are hidden by default (untick the box to see them).',
            'A clearer wait when questions are slow: the screen now tells you why, Check again restarts generation right away, and more questions are kept ready so fast answerers wait less. If none are ready, practice can serve a question another learner has already answered (never one you have seen).'
        ]
    },
    {
        version: 'v0.13.0',
        date: 'Nov 5, 2026',
        items: [
            'You now get an email when a problem you reported is fixed or closed, and when a study resource or suggestion you sent is reviewed.'
        ]
    },
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
