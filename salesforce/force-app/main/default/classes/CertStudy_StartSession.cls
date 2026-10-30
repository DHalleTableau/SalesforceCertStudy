/** Agentforce action: Start Practice Session. Thin wrapper over CertStudyService. */
public with sharing class CertStudy_StartSession {
    public class Request {
        @InvocableVariable(label='Cert Codes' description='Comma-separated certification codes from Find Certifications, e.g. AI-201 or AI-201, DATA-CON-101.' required=true)
        public String certCodes;
        @InvocableVariable(label='Prerequisite Answers' description='Answers to earlier NEEDS_ANSWER questions, as CODE=yes or CODE=no pairs separated by semicolons, e.g. AI-201=no. Include every answer given so far.')
        public String prerequisiteAnswers;
        @InvocableVariable(label='User Key' description='Optional. Leave blank to use the current user. Only set this when an interface supplies its own learner id, such as a Slack user ID.')
        public String userKey;
    }

    public class Result {
        @InvocableVariable(label='Message' description='Markdown to show the learner exactly as written, without summarizing or rewording.')
        public String message;
    }

    @InvocableMethod(label='Start Practice Session' description='Starts a new practice session for one or more certifications and returns the overview plus the first question. If the reply starts with NEEDS_ANSWER, ask the learner the yes/no question and call again with the same cert codes plus the answer.')
    public static List<Result> run(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request r : requests) {
            Result res = new Result();
            res.message = CertStudyService.startSession(r.userKey, r.certCodes, r.prerequisiteAnswers);
            results.add(res);
        }
        return results;
    }
}
