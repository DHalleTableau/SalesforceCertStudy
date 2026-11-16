// Load per-cert answer formats (and delivered question counts) from data/cert_format_mix.csv.
// Run from the salesforce/ folder:
//   sf apex run --file scripts/apex/load_format_mix.apex --target-org certstudy
// Only existing certs are updated (nothing is created). Unmatched names are listed in the debug log.
// Set purgeMismatched = true to also delete unclaimed Ready questions whose format is not in the cert's mix,
// so the pool refills with the right formats. Answered questions and history are never touched.
Boolean purgeMismatched = false;

List<List<Object>> data = new List<List<Object>>{
    new List<Object>{ 'Advanced Field Service Accredited Professional', '1of4|2of4|2of5', null },
    new List<Object>{ 'Consumer Goods Cloud: Trade Promotion Management Accredited Professional', '1of4|2of4|2of5', null },
    new List<Object>{ 'Contact Center Accredited Professional', '1of4|2of4|2of5', null },
    new List<Object>{ 'CPQ and Billing Consultant Accredited Professional', '1of4|2of4|2of5', null },
    new List<Object>{ 'Energy and Utilities Cloud Accredited Professional', '1of4|2of4|2of5', null },
    new List<Object>{ 'Heroku Developer Accredited Professional', '1of4|2of4|2of5', null },
    new List<Object>{ 'Loyalty Management Accredited Professional', '1of4|2of4|2of5', null },
    new List<Object>{ 'Marketing Cloud Advanced Cross Channel Accredited Professional', '1of4|2of4|2of5', null },
    new List<Object>{ 'Marketing Cloud Intelligence Accredited Professional', '1of4|2of4|2of5', null },
    new List<Object>{ 'Marketing Cloud Personalization Accredited Professional', '1of4|2of4|2of5', null },
    new List<Object>{ 'Media Cloud Accredited Professional', '1of4|2of4|2of5', null },
    new List<Object>{ 'Net Zero Cloud Accredited Professional', '1of4|2of4|2of5', null },
    new List<Object>{ 'Order Management Administrator Accredited Professional', '1of4|2of4|2of5', null },
    new List<Object>{ 'Order Management Developer Accredited Professional', '1of4|2of4|2of5', null },
    new List<Object>{ 'Process Automation Accredited Professional', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Accredited Agentforce 360 for Public Sector Professional', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Accredited Agentforce Communications Professional', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Accredited Agentforce Consumer Goods Professional', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Accredited Agentforce Financial Services Professional', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Accredited Agentforce Health Professional', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Accredited Agentforce Manufacturing Professional', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Accredited B2B Commerce Administrator Professional', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Accredited B2B Commerce Developer Professional', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Certified Agentforce Field Service and Operations Consultant', '1of3', null },
    new List<Object>{ 'Salesforce Certified Agentforce Life Sciences Consultant', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Certified Agentforce Nonprofit Consultant', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Certified Agentforce Sales Consultant', '1of4|2of4|2of5|3of5', null },
    new List<Object>{ 'Salesforce Certified Agentforce Sales Foundations', '1of3', null },
    new List<Object>{ 'Salesforce Certified Agentforce Service Consultant', '1of3', null },
    new List<Object>{ 'Salesforce Certified Agentforce Specialist', '1of3', null },
    new List<Object>{ 'Salesforce Certified Application Architect', 'NONE', null },
    new List<Object>{ 'Salesforce Certified B2B Solution Architect', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Certified B2C Commerce Architect', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Certified B2C Commerce Developer', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Certified B2C Solution Architect', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Certified Business Analyst', '1of3', null },
    new List<Object>{ 'Salesforce Certified CPQ Administrator', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Certified CRM Analytics and Einstein Discovery Consultant', '1of3', null },
    new List<Object>{ 'Salesforce Certified Data 360 Consultant', '1of3', null },
    new List<Object>{ 'Salesforce Certified Education Cloud Consultant', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Certified Experience Cloud Consultant', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Certified Heroku Architect', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Certified Industries CPQ Developer', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Certified JavaScript Developer', '1of4|2of4|2of5|3of5', null },
    new List<Object>{ 'Salesforce Certified Marketing Cloud Account Engagement Consultant', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Certified Marketing Cloud Account Engagement Specialist', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Certified Marketing Cloud Engagement Administrator', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Certified Marketing Cloud Engagement Consultant', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Certified Marketing Cloud Engagement Developer', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Certified Marketing Cloud Engagement Foundations', '1of3', null },
    new List<Object>{ 'Salesforce Certified Marketing Cloud Engagement Specialist', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Certified Marketing Cloud Next Consultant', '1of3', null },
    new List<Object>{ 'Salesforce Certified MuleSoft Catalyst Consultant', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Certified MuleSoft Developer', '1of4', null },
    new List<Object>{ 'Salesforce Certified MuleSoft Developer II', '1of4', null },
    new List<Object>{ 'Salesforce Certified MuleSoft Hyperautomation Developer', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Certified MuleSoft Integration Foundations', '1of4', null },
    new List<Object>{ 'Salesforce Certified MuleSoft Platform Architect', '1of4', null },
    new List<Object>{ 'Salesforce Certified MuleSoft Platform Integration Architect', '1of4', null },
    new List<Object>{ 'Salesforce Certified Nonprofit Success Pack Consultant', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Certified Omnistudio Consultant', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Certified Omnistudio Developer', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Certified Platform Administrator', '1of4|2of4|2of5|3of5', 65 },
    new List<Object>{ 'Salesforce Certified Platform Administrator II', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Certified Platform App Builder', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Certified Platform Data Architect', '1of3', null },
    new List<Object>{ 'Salesforce Certified Platform Developer', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Certified Platform Developer II', '1of4|2of4|2of5|3of5', null },
    new List<Object>{ 'Salesforce Certified Platform Development Lifecycle and Deployment Architect', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Certified Platform Foundations', '1of3', null },
    new List<Object>{ 'Salesforce Certified Platform Identity and Access Management Architect', '1of4|2of4|2of5|3of5', null },
    new List<Object>{ 'Salesforce Certified Platform Integration Architect', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Certified Platform Sharing and Visibility Architect', '1of3', null },
    new List<Object>{ 'Salesforce Certified Platform Strategy Designer', '1of3', null },
    new List<Object>{ 'Salesforce Certified Platform User Experience Designer', '1of3', null },
    new List<Object>{ 'Salesforce Certified Revenue Management Consultant', '1of3', null },
    new List<Object>{ 'Salesforce Certified Slack Administrator', '1of4', 65 },
    new List<Object>{ 'Salesforce Certified Slack Consultant', '1of4', null },
    new List<Object>{ 'Salesforce Certified Slack Developer', '1of4', null },
    new List<Object>{ 'Salesforce Certified System Architect', 'NONE', null },
    new List<Object>{ 'Salesforce Certified Tableau Architect', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Certified Tableau Consultant', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Certified Tableau Data Analyst', '1of4|2of4|2of5', null },
    new List<Object>{ 'Salesforce Certified Tableau Desktop Foundations', '1of4|2of4', null },
    new List<Object>{ 'Salesforce Certified Tableau Next Consultant', '1of3', null },
    new List<Object>{ 'Salesforce Certified Tableau Server Administrator', '1of4|2of4', null },
    new List<Object>{ 'Salesforce Certified Technical Architect - Architect Evaluation', 'NONE', null },
    new List<Object>{ 'Salesforce Certified Technical Architect - Architect Review Board Exam', 'NONE', null }
};

Map<String, Cert__c> byCode = new Map<String, Cert__c>();
for (Cert__c c : [SELECT Id, Cert_Code__c FROM Cert__c]) byCode.put(c.Cert_Code__c.toLowerCase(), c);

List<Cert__c> toUpdate = new List<Cert__c>();
List<String> missing = new List<String>();
for (List<Object> row : data) {
    Cert__c c = byCode.get(((String) row[0]).toLowerCase());
    if (c == null) {
        missing.add((String) row[0]);
        continue;
    }
    Decimal delivered = row[2] == null ? null : Decimal.valueOf(String.valueOf(row[2]));
    toUpdate.add(new Cert__c(Id = c.Id, Format_Mix__c = (String) row[1], Delivered_Questions__c = delivered));
}
update toUpdate;
System.debug('Updated ' + toUpdate.size() + ' certs. Not found in the org (' + missing.size() + '): ' + String.join(missing, ' | '));

if (purgeMismatched) {
    Integer deleted = 0;
    for (Cert__c c : [SELECT Id, Format_Mix__c FROM Cert__c WHERE Format_Mix__c != null AND Format_Mix__c != 'NONE']) {
        List<String> keep = CertStudyGenerator.formatMix(c);
        if (keep.isEmpty()) continue;
        List<Question__c> stale = [
            SELECT Id FROM Question__c
            WHERE Cert__c = :c.Id AND Status__c = 'Ready' AND Study_Session__c = null AND Format__c NOT IN :keep
        ];
        deleted += stale.size();
        delete stale;
    }
    System.debug('Deleted ' + deleted + ' unclaimed questions in formats the exam does not use.');
}
