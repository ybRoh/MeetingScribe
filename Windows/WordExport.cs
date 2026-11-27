using System.IO.Compression;
using System.Text;
using System.Xml;

namespace MeetingScribe;

internal static class WordExport
{
    public static void Save(string text, string destination, string templates)
    {
        using var bytes = new MemoryStream();
        using (var zip = new ZipArchive(bytes, ZipArchiveMode.Create, leaveOpen: true))
        {
            zip.CreateEntryFromFile(Path.Combine(templates, "[Content_Types].xml"), "[Content_Types].xml");
            zip.CreateEntryFromFile(Path.Combine(templates, "_rels", ".rels"), "_rels/.rels");
            using var document = zip.CreateEntry("word/document.xml").Open();
            using var xml = XmlWriter.Create(document, new XmlWriterSettings { Encoding = new UTF8Encoding(false) });
            const string ns = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
            xml.WriteStartDocument();
            xml.WriteStartElement("w", "document", ns);
            xml.WriteStartElement("w", "body", ns);
            foreach (var line in text.Replace("\r\n", "\n").Split('\n'))
            {
                xml.WriteStartElement("w", "p", ns);
                xml.WriteStartElement("w", "r", ns);
                xml.WriteStartElement("w", "t", ns);
                xml.WriteAttributeString("xml", "space", null, "preserve");
                xml.WriteString(string.Concat(line.EnumerateRunes().Where(rune =>
                    rune.Value == 9 || rune.Value is >= 0x20 and <= 0xD7FF or >= 0xE000 and <= 0xFFFD or >= 0x10000)));
                xml.WriteEndElement();
                xml.WriteEndElement();
                xml.WriteEndElement();
            }
            xml.WriteEndDocument();
        }
        string temporary = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(destination))!, Guid.NewGuid() + ".tmp");
        try
        {
            File.WriteAllBytes(temporary, bytes.ToArray());
            File.Move(temporary, destination, overwrite: true);
        }
        finally { File.Delete(temporary); }
    }
}
