/**
 * Login Discovery handler for the Cert Study site: learners type only their
 * email address; the hidden ".certstudy" username (see CertStudySelfRegHandler)
 * never has to be remembered. Sends a one-time email code (passwordless login).
 *
 * Only users created by self-registration match (username ends with
 * USERNAME_SUFFIX), so an internal user who shares the email never can.
 */
global without sharing class CertStudyLoginDiscoveryHandler implements Auth.LoginDiscoveryHandler {
    public static final String GENERIC_ERROR = 'No Cert Study account found for that email. New here? Click "Sign Up" below the Log In button and register with your @salesforce.com email first.';

    global PageReference login(String identifier, String startUrl, Map<String, String> requestAttributes) {
        Id userId = findUserId(identifier);
        if (userId == null) {
            // DiscoveryCustomErrorException's message is shown on the login page.
            throw new Auth.DiscoveryCustomErrorException(GENERIC_ERROR);
        }
        return Site.passwordlessLogin(userId, new List<Auth.VerificationMethod>{ Auth.VerificationMethod.EMAIL }, startUrl);
    }

    /** The active self-registered user with this email, or null if none or ambiguous. */
    @TestVisible
    private static Id findUserId(String identifier) {
        if (String.isBlank(identifier)) return null;
        String email = identifier.trim().toLowerCase();
        String usernameSuffix = '%' + CertStudySelfRegHandler.USERNAME_SUFFIX;
        List<User> matches = [
            SELECT Id
            FROM User
            WHERE Email = :email AND IsActive = true AND Username LIKE :usernameSuffix
            LIMIT 2
        ];
        return matches.size() == 1 ? matches[0].Id : null;
    }
}
