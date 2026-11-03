# Giai đoạn 5: Dashboard

Dashboard web thay cho Power BI (máy phát triển chưa cài Power BI Desktop). Cùng vai trò:
đọc star schema/view trong `TelcoDW.mart`, không tự tính lại chỉ số.

**Chạy:** `python -m src.dashboard.app` rồi mở <http://127.0.0.1:5000>.

## 1. Kiến trúc

```
TelcoDW.mart (view)  ──>  Flask API (src/dashboard/app.py)  ──>  SPA HTML/JS + ECharts (src/dashboard/static)
```

| Thành phần | Vai trò |
|---|---|
| `app.py` | Mỗi endpoint `/api/<tên>` trả JSON của một view. Cache theo `batch_id` ETL mới nhất: chạy lại ETL là dashboard tự lấy số mới, không cần khởi động lại |
| `templates/index.html` | Khung trang: sidebar, topbar có bộ lọc kỳ, drawer drill-through |
| `static/app.js` | Router theo hash (`#overview`, `#drivers`...), dựng biểu đồ, tiêu đề insight tính từ dữ liệu |
| `static/app.css` | Token màu sáng/tối; bảng màu biểu đồ đã kiểm định cho người mù màu (CVD) |

Ánh xạ khái niệm Power BI sang bản web:

| Power BI | Bản web |
|---|---|
| Data model, quan hệ 1-nhiều | Star schema + view trong `mart` (xem [02_data_warehouse.md](02_data_warehouse.md)) |
| DAX measure | Cột tính sẵn trong view (`v_kpi_monthly`: churn_rate, arpu_usd, mrr_vs_target_pct, mrr_mom_pct...) |
| Slicer | Bộ lọc kỳ (24 tháng / 2024 / 2025) trên trang Overview |
| Drill-through | Bấm phân khúc → drawer danh sách khách, tìm kiếm, sắp xếp, xuất CSV |
| What-if parameter | Thanh trượt tỷ lệ chuyển đổi, chiết khấu, tầm nhìn |
| Theme JSON | Biến CSS trong `app.css` (sáng/tối) |

## 2. Thiết kế từng trang

Tiêu đề biểu đồ và khung insight được **tính từ dữ liệu** (không viết cứng). Khi số thay đổi thì câu chữ đổi theo.

### 2.1 Finance Overview
- **Mục tiêu:** Tháng này có đạt chỉ tiêu churn và MRR không, và churn đang làm mất bao nhiêu doanh thu?
- **Người xem:** Ban giám đốc, Finance.
- **Bộ lọc:** kỳ 24 tháng / 2024 / 2025.
- **Nội dung:**
  - Khung insight.
  - 5 thẻ KPI có so sánh: khách cuối kỳ so với đầu kỳ; churn bình quân so với chỉ tiêu; MRR so với chỉ tiêu; MRR mất; ARPU.
  - MRR so với đường chỉ tiêu, có đánh dấu tháng ước lượng và mốc tăng giá Fiber.
  - Churn rate dạng cột, cột đỏ là tháng vượt chỉ tiêu.
  - MRR mất do churn.
  - Ticket Billing so với dải bình thường ±2σ, đóng vai trò cảnh báo sớm.
- **Ví dụ tiêu đề:** "Churn vượt chỉ tiêu 19/24 tháng; đỉnh 3,10% vào 2025-04".
- **Nguồn:** `v_kpi_monthly`, `v_anomaly_monthly`.

### 2.2 Churn Drivers
- **Mục tiêu:** Yếu tố nào gắn với churn cao, và ảnh hưởng của Fiber có thật hay chỉ do cơ cấu hợp đồng?
- **Người xem:** Marketing, Product.
- **Nội dung:**
  - 9 biểu đồ nhỏ, mỗi biểu đồ một driver, có đường bình quân.
  - Fiber/DSL/Không internet so trong từng loại hợp đồng.
  - Đường retention bình quân, chỉ vẽ các mốc có ≥ 6 cohort.
  - Heatmap cohort.
- **Ví dụ tiêu đề:** "Fiber churn gấp 1,7–3,7 lần DSL trong cùng loại hợp đồng", "Mất 13,9% khách ngay sau kỳ cước đầu tiên".
- **Nguồn:** `v_churn_drivers`, `v_churn_internet_by_contract`, `v_cohort_retention`.

### 2.3 Risk Segments
- **Mục tiêu:** Ưu tiên chăm sóc nhóm khách nào, và cụ thể là những khách nào?
- **Người xem:** Customer Care, Sales.
- **Nội dung:**
  - 5 thẻ KPI.
  - Biểu đồ bong bóng: trục ngang là tỷ trọng khách, trục dọc là churn so với bình quân, kích thước là MRR.
  - Top MRR dự kiến mất.
  - Bảng 18 phân khúc.
  - **Drill-through:** bấm bong bóng, cột hoặc dòng để mở drawer danh sách khách đang hoạt động (cước, ticket, tỷ lệ trả trễ...), có tìm kiếm, sắp xếp và xuất CSV.
- **Định nghĩa rủi ro cao:** đồng thời ≥ 5% khách, churn ≥ 1,5 lần bình quân và ≥ 10% MRR.
- **Nguồn:** `v_risk_segments`, `v_customer_profile`.

### 2.4 What-if Scenario
- **Mục tiêu:** Chuyển X% khách Month-to-month sang hợp đồng 1 năm thì giữ lại bao nhiêu doanh thu, và chiết khấu tối đa bao nhiêu thì vẫn có lãi?
- **Người xem:** Ban giám đốc, Marketing.
- **Tham số:** tỷ lệ chuyển đổi 0–50%, chiết khấu 0–30%, tầm nhìn 6–24 tháng.
- **Nội dung:**
  - Hai đường số khách còn lại: theo nhịp churn One year và theo nhịp Month-to-month.
  - 5 thẻ kết quả, trong đó có điểm hoà vốn.
  - Bảng số liệu nền.
- **Kiểm chứng:** công thức trùng [07_whatif_contract.sql](../sql/analysis/07_whatif_contract.sql). Ở mức 20%/12 tháng, cả hai cho cùng kết quả: 444 khách, +$8.404 MRR, $59.162 doanh thu, hoà vốn ở chiết khấu 18,7%.
- **Nguồn:** `v_whatif_contract_base`.

### 2.5 Data Quality
- **Mục tiêu:** Số liệu trên dashboard có tin được không? Lần ETL gần nhất ra sao?
- **Người xem:** Data team, và bất kỳ ai nghi ngờ con số.
- **Nội dung:**
  - Thẻ PASS/WARN/FAIL.
  - Bảng 26 kiểm tra theo nhóm, có giá trị trước (stg) và sau (clean/mart).
  - Biểu đồ bản ghi bị loại theo lý do.
  - Các bước ETL với số dòng và thời gian chạy.
- **Ví dụ tiêu đề:** "24/26 kiểm tra đạt; 2 cảnh báo đã biết, 0 lỗi cần xử lý".
- **Nguồn:** `v_dq_latest`, `v_rejected_summary`, `dbo.etl_log`.

## 3. Quy tắc trình bày

- Màu gắn với thực thể, không theo thứ hạng: Fiber luôn xanh, DSL cam, không internet xanh ngọc. Đỏ chỉ dùng cho trạng thái xấu (vượt chỉ tiêu, rủi ro cao, bất thường) và luôn đi kèm nhãn.
- Không dùng biểu đồ hai trục tung: MRR và churn rate nằm ở hai biểu đồ riêng.
- Mọi biểu đồ có tooltip khi rê chuột. Có ≥ 2 chuỗi dữ liệu thì có chú giải. Giá trị chỉ ghi trên các điểm cần nhấn mạnh.
- Chế độ tối có bộ màu riêng (không đảo màu tự động), lưu lựa chọn ở trình duyệt.
- Số định dạng kiểu Việt Nam (1.234,5), USD dùng `$`.
- Bố cục co giãn: dưới 900px, sidebar thu thành menu và lưới chuyển thành 1 cột.
