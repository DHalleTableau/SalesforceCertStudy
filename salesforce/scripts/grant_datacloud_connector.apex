// Gives the "Data Cloud Salesforce Connector" permission set (sfdc_a360_sfcrm_data_extract)
// read + view-all on the Cert Study objects and read on every permissionable custom field,
// so CRM data streams can ingest them. Safe to re-run.
List<String> objs = new List<String>{
    'Cert__c', 'Question__c', 'Study_Session__c', 'Answer__c', 'Question_Report__c',
    'Contribution__c', 'User_Cert__c', 'Study_Link__c', 'User_Study_Link__c'
};
PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'sfdc_a360_sfcrm_data_extract' LIMIT 1];

Map<String, ObjectPermissions> op = new Map<String, ObjectPermissions>();
for (ObjectPermissions o : [SELECT Id, SobjectType FROM ObjectPermissions WHERE ParentId = :ps.Id AND SobjectType IN :objs]) op.put(o.SobjectType, o);
List<ObjectPermissions> ops = new List<ObjectPermissions>();
for (String o : objs) {
    ObjectPermissions p = op.containsKey(o) ? op.get(o) : new ObjectPermissions(ParentId = ps.Id, SobjectType = o);
    p.PermissionsRead = true;
    p.PermissionsViewAllRecords = true;
    ops.add(p);
}
upsert ops;

Set<String> have = new Set<String>();
for (FieldPermissions f : [SELECT Field FROM FieldPermissions WHERE ParentId = :ps.Id AND SobjectType IN :objs AND PermissionsRead = true]) have.add(f.Field);
Map<String, FieldPermissions> existing = new Map<String, FieldPermissions>();
for (FieldPermissions f : [SELECT Id, Field FROM FieldPermissions WHERE ParentId = :ps.Id AND SobjectType IN :objs]) existing.put(f.Field, f);
List<FieldPermissions> fps = new List<FieldPermissions>();
for (String o : objs) {
    for (Schema.SObjectField sf : Schema.getGlobalDescribe().get(o).getDescribe().fields.getMap().values()) {
        Schema.DescribeFieldResult d = sf.getDescribe();
        if (!d.isCustom() || !d.isPermissionable()) continue;
        String key = o + '.' + d.getName();
        if (have.contains(key)) continue;
        FieldPermissions f = existing.containsKey(key) ? existing.get(key) : new FieldPermissions(ParentId = ps.Id, SobjectType = o, Field = key);
        f.PermissionsRead = true;
        fps.add(f);
    }
}
Database.UpsertResult[] res = Database.upsert(fps, false);
Integer ok = 0; List<String> bad = new List<String>();
for (Integer i = 0; i < res.size(); i++) {
    if (res[i].isSuccess()) ok++; else bad.add(fps[i].Field + ': ' + res[i].getErrors()[0].getMessage());
}
System.debug(LoggingLevel.ERROR, 'GRANT objects=' + ops.size() + ' fieldsGranted=' + ok + ' alreadyHad=' + have.size() + ' failed=' + bad.size());
for (String b : bad) System.debug(LoggingLevel.ERROR, 'GRANT fail ' + b);
