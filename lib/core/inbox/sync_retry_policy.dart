/// One bounded retry schedule shared by notifications and legacy sync.
Duration syncRetryDelay(int failures) =>
    Duration(seconds: (1 << failures.clamp(1, 6)).clamp(2, 60));
