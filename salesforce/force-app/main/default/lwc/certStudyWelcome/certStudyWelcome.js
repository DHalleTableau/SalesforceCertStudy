import { LightningElement, api } from 'lwc';

/**
 * Guest-safe welcome panel for the site's Login page (no Apex). Makes sign-up obvious:
 * a big "Create your account" button above the platform login form.
 * Set signUpUrl in Builder to the URL of the login page's own "Sign Up" link.
 */
export default class CertStudyWelcome extends LightningElement {
    @api signUpUrl = '';
    @api heading = 'Salesforce Cert Study';
    @api tagline = 'Practice questions and mock exams for Salesforce certifications, with explanations.';

    get hasSignUp() {
        return !!(this.signUpUrl && this.signUpUrl.trim());
    }

    goSignUp() {
        if (this.hasSignUp) window.location.assign(this.signUpUrl.trim());
    }
}
