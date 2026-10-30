/** Agentforce action: Get Next Practice Question. Thin wrapper over CertStudyService. */
public with sharing class CertStudy_NextQuestion {
    public class Request {
        @InvocableVariable(label='User Key' description='Optional. Leave blank to use the current user. Only set this when an interface supplies its own learner id, such as a Slack user ID.')
        public String userKey;
    }

    public class Result {
        @InvocableVariable(label='Message' description='Markdown to show the learner exactly as written, without summarizing or rewording.')
        public String message;
    }

    @InvocableMethod(label='Get Next Practice Question' description='Shows the current unanswered question, or the next question in the active practice session.')
    public static List<Result> run(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request r : requests) {
            Result res = new Result();
            res.message = CertStudyService.nextQuestion(r.userKey);
            results.add(res);
        }
        return results;
    }
}
