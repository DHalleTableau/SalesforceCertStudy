/** Agentforce action: Find Certifications. Thin wrapper over CertStudyService. */
public with sharing class CertStudy_FindCerts {
    public class Request {
        @InvocableVariable(label='Search Text' description='Optional words from the certification name or code, e.g. agentforce or AI-201. Leave blank to list all.')
        public String searchText;
    }

    public class Result {
        @InvocableVariable(label='Message' description='Markdown to show the learner exactly as written, without summarizing or rewording.')
        public String message;
    }

    @InvocableMethod(label='Find Certifications' description='Lists Salesforce certifications that can be practiced, with their codes. Use before starting a session to get the exact cert code.')
    public static List<Result> run(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request r : requests) {
            Result res = new Result();
            res.message = CertStudyService.findCerts(r.searchText);
            results.add(res);
        }
        return results;
    }
}
