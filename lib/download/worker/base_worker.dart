abstract class BaseWorker<TTask>{
  TTask get task;
  Future<void> start();
  void pause();
  Future<void> cancel({bool deleteFiles = false});
}
