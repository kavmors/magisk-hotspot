import java.io.ByteArrayOutputStream;
import java.net.Inet4Address;
import java.net.InetAddress;

public final class DnsMessageTest {
    public static void main(String[] args) throws Exception {
        Inet4Address address = (Inet4Address) InetAddress.getByName("192.168.50.1");

        byte[] query = query("Magisk.Home.Arpa", 1);
        byte[] response = DnsMessage.answerIfLocal(query, "magisk.home.arpa", address);
        check(response != null, "A query did not receive a local response");
        check(u16(response, 0) == 0x1234, "transaction ID changed");
        check((u16(response, 2) & 0x8480) == 0x8480, "response flags are incomplete");
        check(u16(response, 6) == 1, "A answer count is not one");
        check(response[response.length - 4] == (byte) 192
                        && response[response.length - 3] == (byte) 168
                        && response[response.length - 2] == 50
                        && response[response.length - 1] == 1,
                "A answer has the wrong address");

        byte[] aaaa = DnsMessage.answerIfLocal(
                query("magisk.home.arpa", 28), "magisk.home.arpa", address);
        check(aaaa != null && u16(aaaa, 6) == 0, "AAAA query should return NODATA");
        check(DnsMessage.answerIfLocal(query("example.com", 1),
                "magisk.home.arpa", address) == null, "unrelated query was answered locally");

        byte[] servfail = DnsMessage.servfail(query("example.com", 1));
        check(servfail != null && (u16(servfail, 2) & 0x000f) == 2,
                "SERVFAIL response is invalid");
        check(DnsMessage.isResponseFor(query("example.com", 1), servfail),
                "matching response was rejected");

        System.out.println("DNS message tests passed");
    }

    private static byte[] query(String name, int type) {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        writeU16(output, 0x1234);
        writeU16(output, 0x0100);
        writeU16(output, 1);
        writeU16(output, 0);
        writeU16(output, 0);
        writeU16(output, 0);
        for (String label : name.split("\\.")) {
            output.write(label.length());
            for (int i = 0; i < label.length(); i++) output.write(label.charAt(i));
        }
        output.write(0);
        writeU16(output, type);
        writeU16(output, 1);
        return output.toByteArray();
    }

    private static int u16(byte[] data, int offset) {
        return ((data[offset] & 0xff) << 8) | (data[offset + 1] & 0xff);
    }

    private static void writeU16(ByteArrayOutputStream output, int value) {
        output.write((value >>> 8) & 0xff);
        output.write(value & 0xff);
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
