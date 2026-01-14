package LinkCheck::ValidateWorker;
use v5.42;
use utf8::all;

use Mooish::Base -standard;
with 'WebFramework::Role::Logger';

use Net::Async::HTTP;
use IO::Async::Loop;

# Simple worker that only validates if a URL is reachable
# Returns: { url => $url, source_page => $source, success => 0|1, status => $code, error => $msg }

sub validate_url ($self, $job) {
  my $url         = $job->{url};
  my $source_page = $job->{source_page};
  
  my $loop = IO::Async::Loop->new;
  my $http = Net::Async::HTTP->new(
    max_connections_per_host => 4,
    timeout                  => $job->{timeout} // 30,
    user_agent => 'LinkChecker/1.0',
  );
  $loop->add($http);

  my ($status, $error);
  
  eval {
    local $SIG{ALRM} = sub { die "job alarm timeout\n" };
    alarm($job->{job_timeout} // 60);
    
    my $req_f = $http->GET($url, headers => ['accept' => '*/*']);
    
    my $deadline = time + ($job->{timeout} // 30);
    while (!$req_f->is_ready) {
      $loop->loop_once(0.05);
      if (time >= $deadline) {
        $req_f->cancel;
        last;
      }
    }
    
    my $resp = eval { $req_f->get };
    
    if ($resp && ($resp->is_success || $resp->code == 403)) {
      $status = $resp->code;
      $error  = undef;
    } else {
      $status = $resp ? $resp->code : 0;
      $error  = $resp ? "HTTP " . $resp->code : "connection failed";
    }
    
    alarm(0);
    1;
  } or do {
    $error  = $@ || "validation failed";
    $status = 0;
    alarm(0);
  };

  return {
    url         => $url,
    source_page => $source_page,
    success     => ($status && ($status >= 200 && $status < 400 || $status == 403)) ? 1 : 0,
    status      => $status // 0,
    error       => $error,
  };
}

1;
