import com.google.zxing.*;
import com.google.zxing.common.HybridBinarizer;
import com.google.zxing.qrcode.QRCodeWriter;
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel;
import java.awt.image.BufferedImage;
import java.io.File;
import java.util.Map;
import javax.imageio.ImageIO;

/** Generate and round-trip verify the bundled companion-download QR using ZXing. */
public class GenerateDownloadQR {
    public static void main(String[] args) throws Exception {
        String url = "https://github.com/mlwn4096/Bridge/releases";
        var matrix = new QRCodeWriter().encode(url, BarcodeFormat.QR_CODE, 344, 344,
            Map.of(EncodeHintType.ERROR_CORRECTION, ErrorCorrectionLevel.M, EncodeHintType.MARGIN, 4));
        BufferedImage image = new BufferedImage(matrix.getWidth(), matrix.getHeight(), BufferedImage.TYPE_INT_RGB);
        for (int y = 0; y < matrix.getHeight(); y++) for (int x = 0; x < matrix.getWidth(); x++)
            image.setRGB(x, y, matrix.get(x, y) ? 0 : 0xFFFFFF);
        int[] rgb = image.getRGB(0, 0, image.getWidth(), image.getHeight(), null, 0, image.getWidth());
        String decoded = new MultiFormatReader().decode(new BinaryBitmap(new HybridBinarizer(
            new RGBLuminanceSource(image.getWidth(), image.getHeight(), rgb)))).getText();
        if (!decoded.equals(url)) throw new IllegalStateException("QR round-trip mismatch");
        ImageIO.write(image, "png", new File(args[0]));
        System.out.println("Verified download QR: " + decoded);
    }
}
