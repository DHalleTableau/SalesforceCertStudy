// Re-derives exam overviews that look like sub-objectives instead of weighted
// sections (more than 10 sections, or every section weighted the same).
// The previous overview is kept if the new attempt still looks wrong.
System.debug('REDERIVE>> ' + CertStudyOverviewJob.rederiveSuspect() + ' cert(s) queued');
