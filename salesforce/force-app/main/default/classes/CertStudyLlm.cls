/**
 * Thin wrapper over the platform's LLM access (Einstein Models API), so
 * generation never needs an external gateway. Tests swap in a fake via
 * CertStudyLlm.instance.
 *
 * Model is set by the CertStudy_Model custom label (Setup > Custom Labels)
 * so it can be changed without a deploy. Check Einstein Studio > Models for
 * the exact API names enabled in this org.
 */
public without sharing class CertStudyLlm {
    public interface Client {
        String generate(String prompt);
    }

    @TestVisible
    private static Client instance;

    public static Client get() {
        if (instance == null) {
            instance = new ModelsApiClient();
        }
        return instance;
    }

    public class ModelsApiClient implements Client {
        public String generate(String prompt) {
            aiplatform.ModelsAPI.createGenerations_Request request = new aiplatform.ModelsAPI.createGenerations_Request();
            request.modelName = System.Label.CertStudy_Model;
            aiplatform.ModelsAPI_GenerationRequest body = new aiplatform.ModelsAPI_GenerationRequest();
            body.prompt = prompt;
            request.body = body;
            aiplatform.ModelsAPI modelsApi = new aiplatform.ModelsAPI();
            aiplatform.ModelsAPI.createGenerations_Response response = modelsApi.createGenerations(request);
            return response.Code200.generation.generatedText;
        }
    }
}
