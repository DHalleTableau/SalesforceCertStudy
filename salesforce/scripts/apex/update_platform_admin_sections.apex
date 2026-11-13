// Update the Platform Administrator exam sections to the current official outline (Nov 2026).
// Run:  sf apex run --file scripts/apex/update_platform_admin_sections.apex --target-org certstudy
// Set purgeOldReady = true to also delete unclaimed Ready questions tagged with the old section names,
// so the pool regenerates under the new sections. Answered questions and history are never touched.
Boolean purgeOldReady = false;

List<Cert__c> certs = [SELECT Id, Name, Domains_JSON__c FROM Cert__c WHERE Name = 'Salesforce Certified Platform Administrator'];
if (certs.size() != 1) {
    System.debug('Expected exactly one Platform Administrator cert, found ' + certs.size());
} else {
    List<Map<String, Object>> doms = new List<Map<String, Object>>{
        new Map<String, Object>{ 'name' => 'Configuration and Setup', 'weight_pct' => 15 },
        new Map<String, Object>{ 'name' => 'Object Manager and Lightning App Builder', 'weight_pct' => 15 },
        new Map<String, Object>{ 'name' => 'Sales and Marketing Applications', 'weight_pct' => 10 },
        new Map<String, Object>{ 'name' => 'Service and Support Applications', 'weight_pct' => 10 },
        new Map<String, Object>{ 'name' => 'Productivity and Collaboration', 'weight_pct' => 10 },
        new Map<String, Object>{ 'name' => 'Data and Analytics Management', 'weight_pct' => 17 },
        new Map<String, Object>{ 'name' => 'Automation', 'weight_pct' => 15 },
        new Map<String, Object>{ 'name' => 'Agentforce', 'weight_pct' => 8 }
    };
    Set<String> keep = new Set<String>();
    for (Map<String, Object> d : doms) keep.add((String) d.get('name'));
    System.debug('Old sections: ' + certs[0].Domains_JSON__c);
    certs[0].Domains_JSON__c = JSON.serialize(doms);
    update certs[0];

    List<Question__c> stale = [
        SELECT Id FROM Question__c
        WHERE Cert__c = :certs[0].Id AND Status__c = 'Ready' AND Study_Session__c = null AND Domain__c NOT IN :keep
    ];
    System.debug('Unclaimed Ready questions under old section names: ' + stale.size());
    if (purgeOldReady && !stale.isEmpty()) {
        delete stale;
        System.debug('Deleted ' + stale.size());
    }
}
