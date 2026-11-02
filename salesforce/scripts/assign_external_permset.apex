// One-off: give CertStudy_External to self-registered users who missed it
// (the original handler assigned CertStudy_User, which external licenses reject).
// Run: sf apex run --file scripts/assign_external_permset.apex --target-org certstudy
Id psId = [SELECT Id FROM PermissionSet WHERE Name = 'CertStudy_External' LIMIT 1].Id;
Set<Id> have = new Set<Id>();
for (PermissionSetAssignment a : [SELECT AssigneeId FROM PermissionSetAssignment WHERE PermissionSetId = :psId]) {
    have.add(a.AssigneeId);
}
List<PermissionSetAssignment> toAdd = new List<PermissionSetAssignment>();
for (User u : [SELECT Id FROM User WHERE Username LIKE '%.certstudy' AND IsActive = true]) {
    if (!have.contains(u.Id)) toAdd.add(new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = psId));
}
insert toAdd;
System.debug('Assigned CertStudy_External to ' + toAdd.size() + ' user(s)');
