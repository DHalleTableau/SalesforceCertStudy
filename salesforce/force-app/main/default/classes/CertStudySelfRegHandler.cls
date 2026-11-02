/**
 * Self-registration handler for the Cert Study Experience Cloud site
 * (Experience Builder > Login & Registration > Self-registration handler).
 *
 * Only @salesforce.com addresses may register; anything else is rejected
 * before a user or contact is created. Enable email verification on the
 * registration page too: this check validates the domain, verification
 * proves the person owns the address.
 */
global without sharing class CertStudySelfRegHandler implements Auth.ConfigurableSelfRegHandler {
    // Not CertStudy_User: that one carries app/tab visibility, which external licenses reject.
    public static final String PERM_SET = 'CertStudy_External';
    public static final String USERNAME_SUFFIX = '.certstudy';
    public static final String REJECT_MESSAGE = 'Registration is limited to @salesforce.com email addresses.';

    public class RegistrationException extends Exception {}

    private static final Pattern ALLOWED = Pattern.compile('^[^@\\s]+@salesforce\\.com$');

    global Id createUser(
        Id accountId,
        Id profileId,
        Map<SObjectField, String> registrationAttributes,
        String password
    ) {
        User u = new User(ProfileId = profileId);
        for (SObjectField f : registrationAttributes.keySet()) {
            u.put(f, registrationAttributes.get(f));
        }
        if (!isAllowed(u.Email)) {
            throw new RegistrationException(REJECT_MESSAGE);
        }

        String email = u.Email.trim().toLowerCase();
        String local = email.substringBefore('@');
        u.Email = email;
        // Usernames are unique across all orgs, so don't claim the bare email address.
        u.Username = email + USERNAME_SUFFIX;
        if (String.isBlank(u.LastName)) u.LastName = local;
        u.Alias = local.left(8);
        u.CommunityNickname = local.left(30) + '_' + String.valueOf(Math.abs(Crypto.getRandomInteger())).left(6);
        u.TimeZoneSidKey = 'America/Los_Angeles';
        u.LocaleSidKey = 'en_US';
        u.EmailEncodingKey = 'UTF-8';
        u.LanguageLocaleKey = 'en_US';

        Id userId = Site.createExternalUser(u, accountId, password);
        if (userId == null) {
            throw new RegistrationException('Could not create your account. Please try again.');
        }
        assignPermSet(userId);
        return userId;
    }

    /** Exactly name@salesforce.com (case-insensitive); rejects lookalikes such as name@salesforce.com.example.org. */
    @TestVisible
    private static Boolean isAllowed(String email) {
        if (String.isBlank(email)) return false;
        return ALLOWED.matcher(email.trim().toLowerCase()).matches();
    }

    /** Future, because user setup records and PermissionSetAssignment can't share a transaction. */
    @future
    private static void assignPermSet(Id userId) {
        List<PermissionSet> ps = [SELECT Id FROM PermissionSet WHERE Name = :PERM_SET LIMIT 1];
        if (ps.isEmpty()) return;
        insert new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = ps[0].Id);
    }
}
