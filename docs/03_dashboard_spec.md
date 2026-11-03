# Giai đoạn 5: Dashboard

Dashboard web thay cho Power BI (máy phát triển chưa cài Power BI Desktop). Nó đọc star schema trong
`TelcoDW.mart` và không tự tính chỉ số: mọi phép tính nằm trong SQL.

**Chạy:** `python -m src.dashboard.app` rồi mở <http://127.0.0.1:5000>.

## 1. Ba trang

| Trang | Cho ai | Làm được gì |
|---|---|---|
| **Khám phá churn** | Lãnh đạo, Marketing, CSKH | Bật/tắt 13 yếu tố (hợp đồng, internet, dịch vụ đi kèm, thanh toán, tenure, nhân khẩu học...) hoặc chọn góc nhìn có sẵn; mọi chỉ số, biểu đồ, bảng tác động và danh sách khách tính lại theo nhóm đang chọn |
| **What-if Scenario** | Lãnh đạo, Marketing | Kéo thanh trượt: tỷ lệ khách chuyển sang hợp đồng 1 năm, chiết khấu, tầm nhìn; xem doanh thu giữ thêm và điểm hoà vốn |
| **Data Quality** | Data team, người nghi ngờ con số | 26 kiểm tra trước/sau làm sạch, bản ghi bị loại theo lý do, các bước ETL gần nhất |

Ba trang báo cáo tĩnh cũ (Overview, Drivers, Risk) được gộp vào trang Khám phá: mỗi trang tĩnh chỉ là
một tổ hợp bộ lọc cố định, nay trở thành "góc nhìn có sẵn" (preset) hoặc một cú bấm.

## 2. Trang Khám phá

**Bộ lọc:** cùng một yếu tố chọn nhiều giá trị là HOẶC, khác yếu tố là VÀ. Bộ lọc lưu trên URL
(`#explore?f=...`), nên gửi link là người khác mở ra đúng góc nhìn đó.

**Góc nhìn có sẵn:** Toàn công ty · Nhóm rủi ro cao (hợp đồng tháng, Fiber, trả tay) · Khách năm đầu ·
Khách Fiber · Không dùng dịch vụ đi kèm · Hợp đồng dài hạn.

**Nội dung (luôn so với toàn công ty):**
- **Insight tự sinh bằng câu thường:** quy mô nhóm, tỷ lệ rời đi so với mức chung, yếu tố tạo khác biệt lớn nhất trong nhóm, tháng rời đi nhiều nhất, MRR dự kiến mất. Nhóm dưới 100 khách có cảnh báo mẫu nhỏ.
- **5 thẻ KPI:** số khách, đã rời đi (24 tháng), rời đi mỗi tháng, MRR hiện tại, MRR dự kiến mất mỗi tháng.
- **Tỷ lệ rời đi và MRR theo tháng.** Khi xem toàn công ty thì so với chỉ tiêu Finance; khi có bộ lọc thì so với toàn công ty. Có đánh dấu mốc tăng giá Fiber.
- **"Yếu tố nào tạo khác biệt lớn nhất?"** Với từng yếu tố, chia tiếp nhóm đang chọn theo các giá trị của nó. Yếu tố chênh lệch nhiều nhất đứng đầu. Bấm một dòng là thêm vào bộ lọc. Nhánh dưới 30 khách hiện mờ, không tính vào mức chênh lệch.
- **Retention theo tháng kể từ khi ký** (chỉ khách bắt đầu từ 12/2023 để tránh thiên lệch sống sót) và **ticket khiếu nại hoá đơn trên 100 khách** (tín hiệu cảnh báo sớm).
- **Danh sách khách đang hoạt động** trong nhóm: tìm kiếm, sắp xếp, xuất CSV cho đội chăm sóc khách hàng.

## 3. Hiệu năng truy vấn

Mỗi lần đổi bộ lọc chỉ gọi **1 stored procedure, 1 round-trip** (`mart.usp_explore`), không có N+1:

| Kỹ thuật | Vì sao |
|---|---|
| Stored procedure tĩnh, bộ lọc truyền dạng JSON (`OPENJSON`) | Kế hoạch thực thi biên dịch một lần rồi tái sử dụng; không có SQL động nên không có đường cho SQL injection |
| Một batch trả 6 result set (KPI, tác động, xu hướng, ticket, retention, mẫu số retention) | Một lượt gọi thay vì nhiều lượt |
| Nhóm đang chọn và toàn công ty tính trong cùng một lần quét (`SUM(CASE WHEN sel = 1 ...)`) | Không chạy truy vấn thứ hai cho "toàn công ty" |
| Bảng cầu nối `mart.customer_factor` (khách × yếu tố × giá trị) | Bộ lọc tuỳ ý chỉ là một phép join với bảng bộ lọc; tác động của 13 yếu tố tính trong một lần gom nhóm thay vì 13 truy vấn |
| `mart.customer_snapshot` (bản vật lý hoá của view hồ sơ khách) | View phải gom 228 nghìn dòng fact mỗi lần đọc (~2-3 giây); bảng snapshot nạp một lần mỗi batch ETL |
| Columnstore index trên `fact_billing`, `fact_tickets`, `customer_factor` | Batch mode: bước tính tác động từ 260 ms xuống 35 ms |
| Cache phía server theo batch ETL + bộ lọc | Bộ lọc đã từng xem trả về ngay (~2 ms); chạy lại ETL là cache tự làm mới |
| Gộp các cú bấm liên tiếp (120 ms) và huỷ request cũ (`AbortController`) | Bấm nhanh nhiều chip không tạo hàng loạt request |

Số đo trên máy phát triển: ~600 ms với SQL động lúc đầu → **~290 ms** sau khi tối ưu (lần đầu một bộ lọc),
**~2 ms** khi trúng cache. Đo từng câu lệnh bằng `sys.dm_exec_query_stats`.

**Kiểm chứng tính đúng:** bộ lọc "hợp đồng tháng + Fiber + trả tay" cho ra 1.508 khách, churn 5,46%/tháng,
MRR $53.883, MRR dự kiến mất $2.941, khớp phân khúc rủi ro trong
[06_risk_segments.sql](../sql/analysis/06_risk_segments.sql). Không lọc thì số theo tháng khớp
`mart.v_kpi_monthly` (ví dụ 2025-04: 4.814 khách, 149 rời đi).

## 4. Quy tắc trình bày

- Câu chữ và nhãn tiếng Việt cho người không chuyên ("Theo tháng", "Trả tay", "Đã rời đi (24 tháng)").
- Màu: xanh là nhóm đang chọn, xám là toàn công ty, nét đứt là chỉ tiêu, đỏ chỉ dùng cho nhánh rời đi cao bất thường (>1,2 lần nhóm) và luôn có nhãn số kèm theo.
- Không dùng biểu đồ hai trục tung; mọi biểu đồ có tooltip; chế độ sáng/tối có bộ màu riêng; co giãn theo màn hình.
