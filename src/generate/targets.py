"""Sinh file chỉ tiêu do "phòng Finance" nhập tay (targets.xlsx).

Chỉ tiêu được dẫn xuất từ số thực tế của dữ liệu đã tái dựng để luôn nằm trong vùng hợp lý
(hơi thách thức hơn thực tế), thay vì bịa một con số không liên quan:
- Churn rate: năm 2024 = 90% mức churn bình quân thực tế 2024; năm 2025 giảm thêm 8%.
- MRR: Finance lập kế hoạch đầu mỗi năm từ MRR thực tế tháng 12 năm trước, cộng tăng trưởng cố định/tháng.
"""
import pandas as pd
from openpyxl import Workbook
from openpyxl.styles import Font

from src import config

CHURN_TARGET_FACTOR_2024 = 0.90
CHURN_TARGET_IMPROVEMENT_2025 = 0.92
MRR_MONTHLY_GROWTH = {2024: 0.006, 2025: 0.005}


def monthly_actuals(timeline: pd.DataFrame, invoices: pd.DataFrame) -> pd.DataFrame:
    act = invoices.groupby("billing_month").agg(
        active_customers=("customer_id", "nunique"), mrr_usd=("amount_usd", "sum"))
    churners = timeline.dropna(subset=["churn_month"]).groupby("churn_month").size()
    act["churners"] = churners.reindex(act.index).fillna(0).astype(int)
    act["churn_rate"] = act["churners"] / act["active_customers"]
    return act


def build_targets(actuals: pd.DataFrame) -> pd.DataFrame:
    year_2024 = [pd.Period(f"2024-{m:02d}", "M") for m in range(1, 13)]
    churn_2024 = round(actuals.loc[year_2024, "churn_rate"].mean() * CHURN_TARGET_FACTOR_2024 * 100, 2)
    churn_target_pct = {2024: churn_2024, 2025: round(churn_2024 * CHURN_TARGET_IMPROVEMENT_2025, 2)}

    rows = []
    for year in (2024, 2025):
        base_mrr = actuals.loc[pd.Period(f"{year - 1}-12", "M"), "mrr_usd"]
        for k in range(1, 13):
            rows.append({
                "month": pd.Period(f"{year}-{k:02d}", "M"),
                "churn_rate_target_pct": churn_target_pct[year],
                "mrr_target_usd": round(base_mrr * (1 + MRR_MONTHLY_GROWTH[year]) ** k, -1),
            })
    return pd.DataFrame(rows)


def write_targets_excel(targets: pd.DataFrame, path=config.TARGETS_XLSX) -> list[dict]:
    """Ghi file Excel giống file nhập tay thật; trả về danh sách lỗi đã cố ý cài để ghi log."""
    wb = Workbook()
    wb.remove(wb.active)
    notes = {pd.Period("2025-03", "M"): "Áp dụng giá Fiber mới từ T3",
             pd.Period("2024-08", "M"): "Billing báo sự cố, số liệu T8 cập nhật sau"}

    # Hai năm do hai người khác nhau nhập nên tiêu đề cột và cách ghi tháng không thống nhất.
    layouts = {
        2024: {"headers": ["Tháng ", "Churn Rate mục tiêu (%)", "MRR  Target (USD)", "Ghi chú"],
               "month_fmt": lambda p: p.to_timestamp().to_pydatetime()},
        2025: {"headers": ["Thang", "Target churn %", "MRR mục tiêu", "ghi chu"],
               "month_fmt": lambda p: f"T{p.month:02d}/{p.year}"},
    }
    for year, layout in layouts.items():
        ws = wb.create_sheet(str(year))
        ws["A1"] = f"KẾ HOẠCH CHỈ TIÊU NĂM {year} - PHÒNG TÀI CHÍNH"
        ws["A1"].font = Font(bold=True, size=13)
        ws["A2"] = f"Người lập: Finance team - cập nhật 15/12/{year - 1}"
        ws.append([])
        ws.append(layout["headers"])
        for cell in ws[4]:
            cell.font = Font(bold=True)
        for r in targets[targets["month"].dt.year == year].itertuples(index=False):
            ws.append([layout["month_fmt"](r.month), r.churn_rate_target_pct, r.mrr_target_usd,
                       notes.get(r.month)])
            if year == 2024:
                ws.cell(row=ws.max_row, column=1).number_format = "mm/yyyy"
        ws.column_dimensions["A"].width = 12
        ws.column_dimensions["B"].width = 24
        ws.column_dimensions["C"].width = 20
        ws.column_dimensions["D"].width = 36
    wb.save(path)

    return [
        {"source_system": "finance_excel", "object": "targets.xlsx", "column": "(header)",
         "error_type": "non_standard_header", "rows_affected": 2,
         "description": "Mỗi sheet có 3 dòng tiêu đề/ghi chú phía trên, header thật nằm ở dòng 4; "
                        "tên cột có dấu, khoảng trắng thừa, đơn vị trong tên và khác nhau giữa sheet 2024/2025"},
        {"source_system": "finance_excel", "object": "targets.xlsx", "column": "Tháng / Thang",
         "error_type": "mixed_date_format", "rows_affected": 12,
         "description": "Sheet 2024 ghi tháng dạng ngày Excel; sheet 2025 ghi dạng chuỗi 'Tmm/yyyy' (12 dòng)"},
        {"source_system": "finance_excel", "object": "targets.xlsx", "column": "Churn Rate mục tiêu (%)",
         "error_type": "unit_inconsistency", "rows_affected": 24,
         "description": "Churn rate nhập theo đơn vị phần trăm (1.2 nghĩa là 1.2%), không phải tỷ lệ 0.012"},
    ]
