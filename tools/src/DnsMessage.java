import java.io.ByteArrayOutputStream;
import java.net.Inet4Address;
import java.util.Locale;

/** DNS wire-format helpers kept independent from Android for host-side tests. */
final class DnsMessage {
    private static final int HEADER_LENGTH = 12;
    private static final int TYPE_A = 1;
    private static final int TYPE_ANY = 255;
    private static final int CLASS_IN = 1;
    private static final int RESPONSE_FLAGS = 0x8480; // QR, AA, RA
    private static final int SERVFAIL = 2;
    private static final int TTL_SECONDS = 60;

    private DnsMessage() {}

    static byte[] answerIfLocal(byte[] query, String domain, Inet4Address answer) {
        Question question = parseQuestion(query);
        if (question == null || !question.name.equals(normalize(domain))
                || question.queryClass != CLASS_IN) {
            return null;
        }

        boolean includeAddress = question.queryType == TYPE_A || question.queryType == TYPE_ANY;
        ByteArrayOutputStream response = startResponse(query, question, 0, includeAddress ? 1 : 0);
        if (includeAddress) {
            writeU16(response, 0xc00c); // Pointer to the QNAME at offset 12.
            writeU16(response, TYPE_A);
            writeU16(response, CLASS_IN);
            writeU32(response, TTL_SECONDS);
            byte[] address = answer.getAddress();
            writeU16(response, address.length);
            response.write(address, 0, address.length);
        }
        return response.toByteArray();
    }

    static byte[] servfail(byte[] query) {
        Question question = parseQuestion(query);
        if (question == null) return null;
        return startResponse(query, question, SERVFAIL, 0).toByteArray();
    }

    static boolean isResponseFor(byte[] query, byte[] response) {
        return query.length >= 2 && response.length >= HEADER_LENGTH
                && query[0] == response[0] && query[1] == response[1]
                && (u16(response, 2) & 0x8000) != 0;
    }

    private static ByteArrayOutputStream startResponse(
            byte[] query, Question question, int responseCode, int answerCount) {
        ByteArrayOutputStream response = new ByteArrayOutputStream(question.endOffset + 16);
        response.write(query[0]);
        response.write(query[1]);
        int queryFlags = u16(query, 2);
        writeU16(response, RESPONSE_FLAGS | (queryFlags & 0x0110) | responseCode);
        writeU16(response, 1);
        writeU16(response, answerCount);
        writeU16(response, 0);
        writeU16(response, 0);
        response.write(query, HEADER_LENGTH, question.endOffset - HEADER_LENGTH);
        return response;
    }

    private static Question parseQuestion(byte[] packet) {
        if (packet == null || packet.length < HEADER_LENGTH || (u16(packet, 2) & 0xf800) != 0
                || u16(packet, 4) != 1) {
            return null;
        }

        StringBuilder name = new StringBuilder();
        int offset = HEADER_LENGTH;
        while (offset < packet.length) {
            int labelLength = packet[offset++] & 0xff;
            if (labelLength == 0) break;
            // Compressed questions are legal but rare. Forward them unchanged
            // instead of building a response with a dangling compression target.
            if ((labelLength & 0xc0) != 0 || labelLength > 63
                    || offset + labelLength > packet.length) {
                return null;
            }
            if (name.length() > 0) name.append('.');
            for (int i = 0; i < labelLength; i++) {
                int value = packet[offset++] & 0xff;
                if ((value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z')
                        || (value >= '0' && value <= '9') || value == '-') {
                    name.append((char) value);
                } else {
                    return null;
                }
            }
        }
        if (offset + 4 > packet.length || name.length() == 0) return null;
        int queryType = u16(packet, offset);
        int queryClass = u16(packet, offset + 2);
        return new Question(
                name.toString().toLowerCase(Locale.US), queryType, queryClass, offset + 4);
    }

    private static String normalize(String domain) {
        String normalized = domain.toLowerCase(Locale.US);
        return normalized.endsWith(".")
                ? normalized.substring(0, normalized.length() - 1) : normalized;
    }

    private static int u16(byte[] data, int offset) {
        return ((data[offset] & 0xff) << 8) | (data[offset + 1] & 0xff);
    }

    private static void writeU16(ByteArrayOutputStream output, int value) {
        output.write((value >>> 8) & 0xff);
        output.write(value & 0xff);
    }

    private static void writeU32(ByteArrayOutputStream output, long value) {
        output.write((int) (value >>> 24) & 0xff);
        output.write((int) (value >>> 16) & 0xff);
        output.write((int) (value >>> 8) & 0xff);
        output.write((int) value & 0xff);
    }

    private static final class Question {
        final String name;
        final int queryType;
        final int queryClass;
        final int endOffset;

        Question(String name, int queryType, int queryClass, int endOffset) {
            this.name = name;
            this.queryType = queryType;
            this.queryClass = queryClass;
            this.endOffset = endOffset;
        }
    }
}
