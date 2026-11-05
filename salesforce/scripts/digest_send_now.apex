// Sends today's digest immediately (only if there is something to report).
Integer n = CertStudyDigest.sendNow();
System.debug(LoggingLevel.ERROR, 'DIGEST sent=' + n + ' admins=' + CertStudyDigest.adminUserIds().size() + ' error=' + CertStudyDigest.lastError);
