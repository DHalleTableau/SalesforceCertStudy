@IsTest
private class CertStudyLoginDiscoveryHandlerTest {
    @IsTest
    static void blankOrUnknownEmailFindsNoUser() {
        Assert.isNull(CertStudyLoginDiscoveryHandler.findUserId(null));
        Assert.isNull(CertStudyLoginDiscoveryHandler.findUserId('  '));
        Assert.isNull(CertStudyLoginDiscoveryHandler.findUserId('nobody@salesforce.com'));
    }

    @IsTest
    static void internalUserWithSameEmailNeverMatches() {
        Assert.isNull(CertStudyLoginDiscoveryHandler.findUserId(UserInfo.getUserEmail()));
    }

    @IsTest
    static void unknownEmailRaisesGenericError() {
        try {
            new CertStudyLoginDiscoveryHandler().login('nobody@salesforce.com', null, new Map<String, String>());
            Assert.fail('expected error');
        } catch (Auth.LoginDiscoveryException e) {
            Assert.areEqual(CertStudyLoginDiscoveryHandler.GENERIC_ERROR, e.getMessage());
        }
    }
}
