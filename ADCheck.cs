using System;
using System.Collections.Generic;
using System.DirectoryServices;
using System.IO;
using System.Net.Mail;
using System.Text;

namespace ADStatusChecker
{
    class UserResult
    {
        public string Username { get; set; }
        public string Status { get; set; }           // Активна / Отключена
        public string LockStatus { get; set; }       // Заблокирована / Нет
        public string ExpiryStatus { get; set; }     // Срок действия учетки
        public string PasswordMustChange { get; set; } // Требуется смена пароля: Да / Нет
        public string PasswordNeverExpires { get; set; } // Бессрочный пароль: Да / Нет
        public bool IsProblematic { get; set; }      // Флаг для подсветки строки и темы ERROR
    }

    class Program
    {
        static void Main(string[] args)
        {
            // 1. Инициализация настроек
            IniReader ini = new IniReader("config.ini");
            string usersFile = ini.ReadValue("General", "UsersFile", "users.txt");
            string usersPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, usersFile);

            if (!File.Exists(usersPath))
            {
                Console.WriteLine("Ошибка: Файл со списком пользователей не найден: " + usersPath);
                return;
            }

            string[] usernames = File.ReadAllLines(usersPath);
            List<UserResult> results = new List<UserResult>();
            bool hasProblems = false;

            Console.WriteLine("Запуск комплексной проверки пользователей в AD...");

            // 2. Сканирование пользователей
            foreach (string user in usernames)
            {
                string username = user.Trim();
                if (string.IsNullOrEmpty(username)) continue;

                UserResult res = CheckAdUserExtended(username);
                if (res.IsProblematic)
                {
                    hasProblems = true;
                }
                results.Add(res);
            }

            // 3. Формирование HTML-отчета
            string htmlTable = BuildHtmlTable(results);

            // 4. Отправка отчета
            string smtpServer = ini.ReadValue("SMTP", "Server");
            if (string.IsNullOrEmpty(smtpServer))
            {
                Console.WriteLine("\n[Настройки SMTP не заданы. Вывод отчета на экран]\n");
                PrintResultsToConsole(results);
            }
            else
            {
                SendEmailReport(ini, htmlTable, hasProblems);
            }

            Console.WriteLine("Работа программы завершена.");
        }

        // Комплексный метод проверки всех атрибутов (Аналог усовершенствованного Варианта 3)
        static UserResult CheckAdUserExtended(string username)
        {
            UserResult result = new UserResult 
            { 
                Username = username,
                Status = "Активна",
                LockStatus = "Не заблокирована",
                ExpiryStatus = "Не ограничен",
                PasswordMustChange = "Нет",
                PasswordNeverExpires = "Нет",
                IsProblematic = false 
            };

            try
            {
                using (DirectorySearcher searcher = new DirectorySearcher())
                {
                    searcher.Filter = string.Format("(samAccountName={0})", username);
                    // Загружаем только необходимые для анализа атрибуты
                    searcher.PropertiesToLoad.Add("userAccountControl");
                    searcher.PropertiesToLoad.Add("lockoutTime");
                    searcher.PropertiesToLoad.Add("accountExpires");
                    searcher.PropertiesToLoad.Add("pwdLastSet");

                    SearchResult searchRes = searcher.FindOne();

                    if (searchRes != null)
                    {
                        // --- 1. АНАЛИЗ USERACCOUNTCONTROL (UAC) ---
                        int uac = (int)searchRes.Properties["userAccountControl"][0];
                        
                        // Флаг 2: ACCOUNTDISABLE
                        if ((uac & 2) != 0) 
                        {
                            result.Status = "Отключена (Disabled)";
                            result.IsProblematic = true;
                        }
                        
                        // Флаг 65536: DONT_EXPIRE_PASSWORD
                        if ((uac & 65536) != 0) 
                        {
                            result.PasswordNeverExpires = "Да (Бессрочный)";
                        }


                        // --- 2. АНАЛИЗ БЛОКИРОВКИ (LOCKOUT) ---
                        if (searchRes.Properties.Contains("lockoutTime"))
                        {
                            long lockoutTime = (long)searchRes.Properties["lockoutTime"][0];
                            if (lockoutTime > 0) 
                            {
                                result.LockStatus = "ЗАБЛОКИРОВАНА";
                                result.IsProblematic = true;
                            }
                        }


                        // --- 3. АНАЛИЗ СМЕНЫ ПАРОЛЯ (MUST CHANGE PASSWORD) ---
                        if (searchRes.Properties.Contains("pwdLastSet"))
                        {
                            long pwdLastSet = (long)searchRes.Properties["pwdLastSet"][0];
                            if (pwdLastSet == 0)
                            {
                                result.PasswordMustChange = "ДА (Требуется смена)";
                                result.IsProblematic = true; // Считаем проблемой, так как во многие внешние сервисы пользователя не пустит
                            }
                        }


                        // --- 4. АНАЛИЗ ИСТЕЧЕНИЯ СРОКА УЧЕТКИ (ACCOUNT EXPIRES) ---
                        if (searchRes.Properties.Contains("accountExpires"))
                        {
                            long expDate = (long)searchRes.Properties["accountExpires"][0];
                            // 0 и 9223372036854775807 означают, что аккаунт не имеет срока действия
                            if (expDate > 0 && expDate != 9223372036854775807L)
                            {
                                DateTime expiryTime = DateTime.FromFileTime(expDate);
                                if (expiryTime < DateTime.Now)
                                {
                                    result.ExpiryStatus = "ИСТЕК (" + expiryTime.ToShortDateString() + ")";
                                    result.IsProblematic = true;
                                }
                                else
                                {
                                    result.ExpiryStatus = "До " + expiryTime.ToShortDateString();
                                }
                            }
                        }
                    }
                    else
                    {
                        result.Status = "Не найден в AD";
                        result.LockStatus = "Н/Д";
                        result.ExpiryStatus = "Н/Д";
                        result.PasswordMustChange = "Н/Д";
                        result.PasswordNeverExpires = "Н/Д";
                        result.IsProblematic = true;
                    }
                }
            }
            catch (Exception ex)
            {
                result.Status = "Ошибка запроса";
                result.LockStatus = ex.Message;
                result.IsProblematic = true;
            }

            return result;
        }

        // Построение расширенной HTML-таблицы результатов
        static string BuildHtmlTable(List<UserResult> results)
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("<table border='1' cellpadding='6' cellspacing='0' style='border-collapse:collapse; font-family:Segoe UI, Arial, sans-serif; font-size:14px;'>");
            sb.Append("<tr style='background-color:#e6e6e6; font-weight:bold;'>");
            sb.Append("<th>Логин</th><th>Состояние записи</th><th>Блокировка (Lockout)</th><th>Срок действия аккаунта</th><th>Требуется смена пароля</th><th>Бессрочный пароль</th>");
            sb.Append("</tr>");

            foreach (var res in results)
            {
                // Если есть проблема — подсвечиваем строку красным, иначе оставляем белой
                string rowBg = res.IsProblematic ? "style='background-color:#ffcccc;'" : "";
                
                sb.AppendFormat("<tr {0}>", rowBg);
                sb.AppendFormat("<td><b>{0}</b></td>", res.Username);
                sb.AppendFormat("<td>{0}</td>", res.Status);
                sb.AppendFormat("<td>{0}</td>", res.LockStatus);
                sb.AppendFormat("<td>{0}</td>", res.ExpiryStatus);
                sb.AppendFormat("<td>{0}</td>", res.PasswordMustChange);
                sb.AppendFormat("<td>{0}</td>", res.PasswordNeverExpires);
                sb.Append("</tr>");
            }

            sb.Append("</table>");
            return sb.ToString();
        }

        // Отправка SMTP (Тема начинается с ERROR или INFO)
        static void SendEmailReport(IniReader ini, string htmlBody, bool hasProblems)
        {
            string server = ini.ReadValue("SMTP", "Server");
            int port = ini.ReadInt("SMTP", "Port", 25);
            string from = ini.ReadValue("SMTP", "From", "ad-monitor@domain.local");
            string to = ini.ReadValue("SMTP", "To");
            string baseSubject = ini.ReadValue("SMTP", "Subject", "Расширенный отчет по статусам AD");

            string prefix = hasProblems ? "ERROR" : "INFO";
            string finalSubject = string.Format("[{0}] {1}", prefix, baseSubject);

            try
            {
                using (MailMessage mail = new MailMessage())
                {
                    mail.From = new MailAddress(from);
                    mail.To.Add(to);
                    mail.Subject = finalSubject;
                    mail.Body = "<h2>Результаты комплексной проверки учетных записей:</h2>" + htmlBody;
                    mail.IsBodyHtml = true;
                    mail.BodyEncoding = Encoding.UTF8;
                    mail.SubjectEncoding = Encoding.UTF8;

                    using (SmtpClient client = new SmtpClient(server, port))
                    {
                        client.UseDefaultCredentials = false; // Строго без авторизации
                        client.Send(mail);
                    }
                }
                Console.WriteLine("Отчет успешно отправлен на адрес: " + to);
            }
            catch (Exception ex)
            {
                Console.WriteLine("Критическая ошибка при SMTP отправке: " + ex.Message);
            }
        }

        // Текстовый вывод в консоль для тестов
        static void PrintResultsToConsole(List<UserResult> results)
        {
            Console.WriteLine(new string('=', 90));
            Console.WriteLine("{0,-12} | {1,-15} | {2,-15} | {3,-15} | {4,-15} | {5}", 
                "Логин", "Статус", "Блокировка", "Срок учетки", "Смена пароля", "Бессрочный");
            Console.WriteLine(new string('-', 90));
            
            foreach (var res in results)
            {
                Console.WriteLine("{0,-12} | {1,-15} | {2,-15} | {3,-15} | {4,-15} | {5}", 
                    res.Username, res.Status, res.LockStatus, res.ExpiryStatus, res.PasswordMustChange, res.PasswordNeverExpires);
            }
            Console.WriteLine(new string('=', 90));
        }
    }
}