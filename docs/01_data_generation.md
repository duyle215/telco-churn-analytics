# Giai đoạn 1: Sinh dữ liệu nguồn

Dữ liệu gốc: IBM Telco Customer Churn (Kaggle), 7.043 khách, 21 cột, là ảnh chụp tại một thời điểm.
Mọi thứ khác trong dự án (dòng thời gian, hoá đơn, thanh toán, ticket, chỉ tiêu) là **SYNTHETIC**,
được dẫn xuất từ dữ liệu gốc bằng `python -m src.generate_sources` với `RANDOM_SEED = 42`.
Không có khách hàng nào bị nhân bản hay upsample: 7.043 khách gốc vẫn là 7.043 khách
(45 dòng trùng trong CRM là lỗi cố ý cài, xem mục 4).

Mọi tham số nằm trong [src/config.py](../src/config.py).

## 1. Giả định tái dựng dòng thời gian

| Giả định | Chi tiết |
|---|---|
| Ngày snapshot | 2025-12-31 |
| Tháng rời đi của khách churn | Rải ngẫu nhiên trong 2024-01..2025-12, mùa vụ nhẹ (biên độ ±12%, cao nhất tháng 1) |
| Tháng ký hợp đồng | `signup_month = anchor_month − tenure`, trong đó anchor = tháng rời đi (khách churn) hoặc 2025-12 (khách còn hoạt động) |
| Kỳ tính cước | Từ `signup_month + 1` đến `anchor_month`, nên mỗi khách có đúng `tenure` hoá đơn và tháng churn là tháng có hoá đơn cuối |
| Khách tenure = 0 | Ký trong 12/2025, chưa có hoá đơn (khớp với 11 giá trị TotalCharges rỗng trong dữ liệu gốc) |
| Hồ sơ khách | Gói dịch vụ, loại hợp đồng, phương thức thanh toán không đổi suốt vòng đời |
| Giá | MonthlyCharges là giá ở tháng có hoá đơn cuối cùng; mỗi hoá đơn dao động ±2% (độ lệch chuẩn) quanh giá |
| Sự kiện bất thường | Từ 2025-03 giá Fiber optic tăng 15%. Hoá đơn Fiber trước 03/2025 = MonthlyCharges / 1.15 (với khách còn dùng sau mốc). Khách churn Fiber có xác suất rơi vào 03, 04, 05/2025 cao gấp 1,6 / 2,6 / 1,9 lần |
| Thanh toán | Hạn 15 ngày. Xác suất trễ cơ sở: Electronic check 12%, Mailed check 10%, tự động 3%. Khách churn ×2, và ×4 trong 3 tháng cuối. 25% khách churn bỏ ngang hoá đơn cuối |
| Ticket | Hệ thống ticket chỉ có dữ liệu từ 2023-01. Cường độ Poisson/khách/tháng tăng khi không có TechSupport (×2,2), dùng Fiber (×1,4), là khách churn (×1,5, thêm ×3 trong 3 tháng cuối). Thêm ticket khiếu nại hoá đơn cho khách Fiber trong 03–05/2025 |
| Chỉ tiêu Finance | Churn 2024 = 90% mức thực tế bình quân 2024; 2025 giảm thêm 8%. MRR = MRR thực tế tháng 12 năm trước × (1 + 0,6%/0,5%)^k |

**Hệ quả cần nhớ khi phân tích:** trước 2024-01 không có khách nào churn (dữ liệu gốc chỉ giữ những
khách còn ở lại đến cửa sổ 24 tháng). Vì vậy churn rate và các KPI liên quan chỉ có ý nghĩa
trong **2024-01..2025-12**. Số khách trước 2024 tăng đều là do thiên lệch sống sót (survivorship bias),
không phải tăng trưởng thật.

## 2. Các hệ thống nguồn

| Nguồn | Đối tượng | Số dòng | Ghi chú thiết kế |
|---|---|---:|---|
| CRM (`src_crm`) | `customers` | 7.088 | Không có khoá chính, nên có thể trùng khách |
| | `contracts` | 7.043 | Ngày và cờ Yes/No lưu NVARCHAR; `end_date` chỉ có ở khách đã rời đi |
| | `services` | 7.043 | 1 dòng/khách, dạng wide giống bảng gốc |
| Billing (`src_billing`) | `invoices` | 223.470 | Không có khoá ngoại sang CRM (hai hệ thống tách rời) |
| | `payments` | 217.709 | Số tiền luôn đúng, nên dùng được để khôi phục amount bị NULL |
| Finance | `data/source/targets.xlsx` | 2 sheet × 12 tháng | Nhập tay |
| Hệ thống ticket | `data/source/support_tickets.csv` | 10.689 | 2023-01..2025-12 |
| API tỷ giá | [src/fx/client.py](../src/fx/client.py) | Theo khoảng tháng có hoá đơn | Xem mục 3 |

DDL nguồn: [sql/ddl/source/](../sql/ddl/source/).

## 3. Tỷ giá USD→VND (API)

- Từ 2024-03 trở đi: [fawazahmed0/exchange-api](https://github.com/fawazahmed0/exchange-api), tỷ giá
  của ngày đầu tiên có dữ liệu trong tháng (22 tháng). API này không có lịch sử trước 2024-03-02.
- Trước 2024-03: World Bank, chỉ số `PA.NUS.FCRF` (tỷ giá chính thức, **bình quân năm**), 74 tháng.
  Các tháng trong cùng một năm nhận cùng một giá trị.
- Không dùng mock hay dữ liệu giả thay thế: nếu API lỗi, bước nạp ghi `FAILED` vào `etl_log` và pipeline
  dừng, để mọi tỷ giá trong kho đều truy được về một API công khai.
- Mỗi bản ghi giữ `provider` và `granularity` để báo cáo ghi rõ nguồn của tỷ giá.

## 4. Lỗi dữ liệu đã cài

Danh sách đầy đủ, sinh tự động mỗi lần chạy: `data/source/injected_errors.csv`. Bảng dưới lấy từ lần chạy với seed 42.

| # | Đối tượng | Cột | Loại lỗi | Số dòng | Mô tả |
|---:|---|---|---|---:|---|
| 1 | contracts | total_charges | blank_value_inherited | 11 | Có sẵn trong dữ liệu gốc |
| 2 | customers | senior_citizen | inconsistent_boolean_inherited | 7.043 | Có sẵn: 0/1 trong khi các cột cờ khác dùng Yes/No |
| 3 | customers | customer_id | duplicate_key_exact | 20 | Trùng y hệt |
| 4 | customers | customer_id | duplicate_key_conflicting | 25 | Khác `dependents`, `updated_at` mới hơn; 10 dòng có khoảng trắng cuối ID |
| 5 | customers | partner | inconsistent_boolean | 425 | Y/yes/1/YES, N/no/0/NO |
| 6 | customers | dependents | inconsistent_boolean | 425 | như trên |
| 7 | customers | gender | extra_whitespace | 80 | |
| 8 | contracts | paperless_billing | inconsistent_boolean | 352 | |
| 9 | contracts | churn_flag | inconsistent_boolean | 281 | |
| 10 | contracts | contract_type | extra_whitespace | 120 | |
| 11 | contracts | payment_method | extra_whitespace | 150 | |
| 12 | contracts | start_date | mixed_date_format | 2.133 | Lẫn `yyyy-mm-dd`, `dd/mm/yyyy`, `yyyymmdd`, `dd-Mon-yyyy` |
| 13 | contracts | end_date | mixed_date_format | 535 | như trên |
| 14 | services | phone_service | inconsistent_boolean | 211 | |
| 15 | services | customer_id | extra_whitespace | 60 | |
| 16 | invoices | billing_month | missing_period | 4.573 | Sự cố billing: không có hoá đơn tháng 2024-08 |
| 17 | payments | invoice_id | missing_period | 4.552 | Thanh toán tương ứng cũng không có |
| 18 | invoices | customer_id | orphan_key | 53 | 8 customer_id không có trong CRM |
| 19 | payments | customer_id | orphan_key | 53 | Thanh toán của các hoá đơn mồ côi |
| 20 | invoices | amount_usd | negative_amount | 120 | Đảo dấu |
| 21 | invoices | amount_usd | null_amount | 150 | Payment vẫn có số tiền đúng |
| 22 | invoices | customer_id | extra_whitespace | 400 | |
| 23 | support_tickets.csv | customer_id | extra_whitespace | 90 | |
| 24 | support_tickets.csv | created_at | mixed_date_format | 2.344 | Lẫn `yyyy-mm-dd HH:MM:SS`, `dd/mm/yyyy HH:MM`, `dd-Mon-yyyy hh:mm AM/PM` |
| 25 | support_tickets.csv | resolved_at | mixed_date_format | 2.288 | như trên |
| 26 | targets.xlsx | (header) | non_standard_header | 2 sheet | Header ở dòng 4; tên cột có dấu, khoảng trắng thừa, kèm đơn vị, khác nhau giữa 2 sheet |
| 27 | targets.xlsx | Tháng / Thang | mixed_date_format | 12 | Sheet 2024 ghi ngày Excel; sheet 2025 ghi chuỗi `Tmm/yyyy` |
| 28 | targets.xlsx | Churn Rate mục tiêu (%) | unit_inconsistency | 24 | Ghi 1.39 nghĩa là 1,39% |

**Lưu ý cho bước làm sạch:** SQL Server bỏ qua khoảng trắng *cuối chuỗi* khi so sánh `=` và `GROUP BY`.
Vì vậy `customer_id <> LTRIM(RTRIM(customer_id))` chỉ bắt được 274/400 dòng lỗi ở `invoices`.
Muốn phát hiện đủ phải dùng `DATALENGTH` hoặc `LIKE '% '`.

## 5. Kiểm tra sau khi sinh (số liệu từ truy vấn thật)

| Kiểm tra | Kết quả |
|---|---|
| Khách churn theo tháng (trước khi cài lỗi) | 54–94/tháng ở các tháng thường; **120 / 149 / 103** trong 03 / 04 / 05/2025 (riêng Fiber: 94 / 121 / 89) |
| Churn rate tháng | 1,11%–2,13% ở các tháng thường; **2,49% / 3,10% / 2,15%** trong 03 / 04 / 05/2025 |
| MRR | 296.869 USD (02/2025) → 320.666 USD (03/2025), tăng 8% do tăng giá Fiber |
| Tỷ lệ thanh toán trễ | Khách churn 22,1%, khách ở lại 6,0%; Electronic check 17,7%, tự động khoảng 3,4% |
| Ticket bình quân/khách (2023–2025) | Không TechSupport: 2,13 (ở lại) / 2,40 (churn); có TechSupport: 1,16 / 1,48 |
| Ticket Billing/tháng | 84 / 73 trong 01 / 02/2025; **233 / 185 / 141** trong 03 / 04 / 05/2025; 88 trong 06/2025 |
| Đối chiếu log lỗi với DB | Khớp: 7.088 dòng customers (7.043 khách duy nhất sau TRIM), 120 âm, 150 NULL, 53 hoá đơn mồ côi của 8 ID, không có hoá đơn 2024-08 |
