@IsTest
private class CertStudySelfRegHandlerTest {
    @IsTest
    static void acceptsOnlyExactSalesforceDomain() {
        Assert.isTrue(CertStudySelfRegHandler.isAllowed('Jane.Doe@salesforce.com'));
        Assert.isTrue(CertStudySelfRegHandler.isAllowed('  jane@SALESFORCE.COM '));
        Assert.isFalse(CertStudySelfRegHandler.isAllowed(null));
        Assert.isFalse(CertStudySelfRegHandler.isAllowed(''));
        Assert.isFalse(CertStudySelfRegHandler.isAllowed('jane@gmail.com'));
        Assert.isFalse(CertStudySelfRegHandler.isAllowed('jane@salesforce.com.example.org'));
        Assert.isFalse(CertStudySelfRegHandler.isAllowed('jane@notsalesforce.com'));
        Assert.isFalse(CertStudySelfRegHandler.isAllowed('jane@mail.salesforce.com'));
        Assert.isFalse(CertStudySelfRegHandler.isAllowed('a@b@salesforce.com'));
        Assert.isFalse(CertStudySelfRegHandler.isAllowed('@salesforce.com'));
    }

    @IsTest
    static void createUserRejectsOtherDomainsBeforeCreatingAnything() {
        Integer usersBefore = [SELECT COUNT() FROM User];
        Integer contactsBefore = [SELECT COUNT() FROM Contact];
        Map<SObjectField, String> attrs = new Map<SObjectField, String>{
            User.Email => 'someone@gmail.com',
            User.LastName => 'Someone'
        };
        try {
            new CertStudySelfRegHandler().createUser(null, UserInfo.getProfileId(), attrs, 'Passw0rd!x');
            Assert.fail('expected rejection');
        } catch (CertStudySelfRegHandler.RegistrationException e) {
            Assert.areEqual(CertStudySelfRegHandler.REJECT_MESSAGE, e.getMessage());
        }
        Assert.areEqual(usersBefore, [SELECT COUNT() FROM User]);
        Assert.areEqual(contactsBefore, [SELECT COUNT() FROM Contact]);
    }
}
