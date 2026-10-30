/** Agentforce action: Practice Session Summary. Thin wrapper over CertStudyService. */
public with sharing class CertStudy_SessionSummary {
    public class Request {
        @InvocableVariable(label='End Session' description='True to end the session after summarizing.')
        public Boolean endSession;
        @InvocableVariable(label='User Key' description='Optional. Leave blank to use the current user. Only set this when an interface supplies its own learner id, such as a Slack user ID.')
        public String userKey;
    }

    public class Result {
        @InvocableVariable(label='Message' description='Markdown to show the learner exactly as written, without summarizing or rewording.')
        public String message;
    }

    @InvocableMethod(label='Practice Session Summary' description='Shows the score, weakest areas and missed questions for the learner most recent session. Set End Session to true when the learner is done practicing.')
    public static List<Result> run(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request r : requests) {
            Result res = new Result();
            res.message = CertStudyService.sessionSummary(r.userKey, r.endSession == true);
            results.add(res);
        }
        return results;
    }
}
