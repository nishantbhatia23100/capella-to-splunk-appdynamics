package demo;

import com.couchbase.client.core.env.SecurityConfig;
import com.couchbase.client.java.*;
import com.couchbase.client.java.env.ClusterEnvironment;
import com.couchbase.client.java.query.QueryOptions;
import java.nio.file.Paths;
import java.time.Duration;
import java.util.concurrent.atomic.AtomicLong;

/** Drives Capella query-node CPU up by running CPU-bound N1QL (no data scanned) from several threads. Time-limited. */
public class CpuBurn {
  public static void main(String[] a) throws Exception {
    String conn = CapellaLoad.req("CB_CONNSTR"), user = CapellaLoad.req("CB_USER"), pass = CapellaLoad.req("CB_PASSWORD");
    int threads = Integer.parseInt(System.getenv().getOrDefault("BURN_THREADS", "8"));
    int seconds = Integer.parseInt(System.getenv().getOrDefault("BURN_SECONDS", "180"));
    int size = Integer.parseInt(System.getenv().getOrDefault("BURN_RANGE", "3000000"));
    String ca = System.getenv().getOrDefault("CB_CA_PEM", "capella-root.pem");
    ClusterEnvironment env = ClusterEnvironment.builder()
        .securityConfig(SecurityConfig.enableTls(true).trustCertificate(Paths.get(ca))).build();
    Cluster cluster = Cluster.connect(conn, ClusterOptions.clusterOptions(user, pass).environment(env));
    cluster.waitUntilReady(Duration.ofSeconds(30));
    String stmt = "SELECT SUM(x * x) AS s FROM ARRAY_RANGE(0, " + size + ") AS x";
    long end = System.currentTimeMillis() + seconds * 1000L;
    AtomicLong done = new AtomicLong(), failed = new AtomicLong();
    System.out.println("Burning: " + threads + " threads, " + seconds + "s, range " + size + ". Ctrl-C to stop.");
    Thread[] ts = new Thread[threads];
    for (int t = 0; t < threads; t++) {
      ts[t] = new Thread(() -> {
        while (System.currentTimeMillis() < end) {
          try { cluster.query(stmt, QueryOptions.queryOptions().timeout(Duration.ofSeconds(60))); done.incrementAndGet(); }
          catch (RuntimeException e) { failed.incrementAndGet(); try { Thread.sleep(500); } catch (InterruptedException ie) { return; } }
        }
      });
      ts[t].start();
    }
    while (System.currentTimeMillis() < end) { Thread.sleep(10000); System.out.println("queries done=" + done + " failed=" + failed); }
    for (Thread t : ts) t.join();
    System.out.println("Finished. queries done=" + done + " failed=" + failed);
    cluster.disconnect(); env.shutdown();
  }
}
