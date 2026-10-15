package demo;

import com.couchbase.client.core.env.SecurityConfig;
import com.couchbase.client.java.*;
import com.couchbase.client.java.env.ClusterEnvironment;
import com.couchbase.client.java.json.JsonObject;
import com.couchbase.client.java.query.QueryResult;
import java.nio.file.Paths;
import java.time.Duration;

/** Generates KV + N1QL traffic against Capella so AppDynamics has Couchbase exit calls to show. */
public class CapellaLoad {
  public static void main(String[] a) throws Exception {
    String conn = req("CB_CONNSTR"), user = req("CB_USER"), pass = req("CB_PASSWORD");
    String bucketName = System.getenv().getOrDefault("CB_BUCKET", "travel-sample");
    int seconds = Integer.parseInt(System.getenv().getOrDefault("RUN_SECONDS", "120"));
    String ca = System.getenv().getOrDefault("CB_CA_PEM", "capella-root.pem");

    ClusterEnvironment env = ClusterEnvironment.builder()
        .securityConfig(SecurityConfig.enableTls(true).trustCertificate(Paths.get(ca))).build();
    Cluster cluster = Cluster.connect(conn, ClusterOptions.clusterOptions(user, pass).environment(env));
    Bucket bucket = cluster.bucket(bucketName);
    bucket.waitUntilReady(Duration.ofSeconds(30));
    Collection col = bucket.defaultCollection();
    System.out.println("Connected to " + bucketName + ". Running " + seconds + "s of load...");

    long end = System.currentTimeMillis() + seconds * 1000L;
    for (int i = 0; System.currentTimeMillis() < end; i++) {
      try { doWork(cluster, col, bucketName, i); }
      catch (RuntimeException e) { System.out.println("i=" + i + " failed: " + e.getMessage()); }
      Thread.sleep(500);
    }
    cluster.disconnect(); env.shutdown();
  }
  /** One unit of work. This is the POJO entry point AppDynamics turns into a business transaction. */
  public static void doWork(Cluster cluster, Collection col, String bucketName, int i) {
    String id = "appd-test::" + (i % 50);
    // Alert test: INJECT_ERROR_EVERY=N makes every Nth call throw out of the entry point, so AppDynamics counts an error.
    int every = Integer.parseInt(System.getenv().getOrDefault("INJECT_ERROR_EVERY", "0"));
    if (every > 0 && i % every == 0) throw new IllegalStateException("injected failure for AppDynamics alert test");
    col.upsert(id, JsonObject.create().put("i", i).put("ts", System.currentTimeMillis()));
    col.get(id);
    if (i % 5 == 0) {
      QueryResult r = cluster.query("SELECT RAW COUNT(*) FROM `" + bucketName + "` WHERE META().id LIKE 'appd-test::%'");
      System.out.println("i=" + i + " count=" + r.rowsAs(Long.class));
    }
    if (i % 20 == 0) { try { col.get("missing-" + i); } catch (Exception e) { /* intentional error for AppD */ } }
  }

  public static String req(String k) { String v = System.getenv(k); if (v == null || v.isEmpty()) throw new IllegalStateException(k + " not set"); return v; }
}
