using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace ADStatusChecker
{
    public class IniReader
    {
        private readonly string _filePath;

        [DllImport("kernel32", CharSet = CharSet.Unicode)]
        private static extern int GetPrivateProfileString(string section, string key, string defaultValue, StringBuilder value, int size, string filePath);

        public IniReader(string fileName)
        {
            // Получаем путь к INI-файлу в той же папке, где лежит EXE
            _filePath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, fileName);
        }

        public string ReadValue(string section, string key, string defaultValue = "")
        {
            StringBuilder buffer = new StringBuilder(255);
            GetPrivateProfileString(section, key, defaultValue, buffer, buffer.Capacity, _filePath);
            return buffer.ToString().Trim();
        }

        public bool ReadBool(string section, string key, bool defaultValue = false)
        {
            string value = ReadValue(section, key, defaultValue.ToString());
            bool result;
            if (bool.TryParse(value, out result))
            {
                return result;
            }
            return defaultValue;
        }

        public int ReadInt(string section, string key, int defaultValue = 0)
        {
            string value = ReadValue(section, key, defaultValue.ToString());
            int result;
            if (int.TryParse(value, out result))
            {
                return result;
            }
            return defaultValue;
        }
    }
}