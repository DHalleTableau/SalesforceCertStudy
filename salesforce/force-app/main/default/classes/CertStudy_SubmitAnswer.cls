/** Agentforce action: Submit Practice Answer. Thin wrapper over CertStudyService. */
public with sharing class CertStudy_SubmitAnswer {
    public class Request {
        @InvocableVariable(label='Answer' description='The option letter or letters the learner chose, e.g. B or B, D.' required=true)
        public String answer;
        @InvocableVariable(label='User Key' description='Optional. Leave blank to use the current user. Only set this when an interface supplies its own learner id, such as a Slack user ID.')
        public String userKey;
    }

    public class Result {
        @InvocableVariable(label='Message' description='Markdown to show the learner exactly as written, without summarizing or rewording.')
        public String message;
    }

    @InvocableMethod(label='Submit Practice Answer' description='Grades the learner answer to the current question, returns the full explanation, the running score, and the next question.')
    public static List<Result> run(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request r : requests) {
            Result res = new Result();
            res.message = CertStudyService.submitAnswer(r.userKey, r.answer);
            results.add(res);
        }
        return results;
    }
}
