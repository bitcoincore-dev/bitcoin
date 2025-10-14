// Copyright (c) 2022 The Bitcoin Core developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <qt/mempooldetail.h>
#include <QtMath>
#include <QMouseEvent>
#include <qt/guiutil.h>
#include <qt/forms/ui_mempooldetail.h>
#include <interfaces/wallet.h>
#include <QSettings>
#include <qt/platformstyle.h>
#include <QSplitter>
#include <QStandardItemModel>
#include <QHeaderView>
#include <limits>


const QSize FONT_RANGE(8, 24);
const char mempoolDetailFontSizeKey[] = "mempoolDetailFontSize";


MempoolDetail::MempoolDetail(QWidget *parent) : QWidget(parent)
{
    if (parent) {
        parent->installEventFilter(this);
        raise();
    }
    //setMouseTracking(true);

    QSettings settings;
    m_font_size = settings.value(mempoolDetailFontSizeKey, 12).toReal();
    if (m_font_size < FONT_RANGE.width() || m_font_size > FONT_RANGE.height()) {
        m_font_size = 12;
    }

    // autoadjust font size
    QGraphicsTextItem testText("jY"); //screendesign expected 27.5 pixel in width for this string
    testText.setFont(QFont(LABEL_FONT, LABEL_TITLE_SIZE, QFont::Light));
    LABEL_TITLE_SIZE *= 27.5/testText.boundingRect().width();
    LABEL_KV_SIZE *= 27.5/testText.boundingRect().width();

    if (MEMPOOL_GRAPH_LOGGING){

        LogPrintf("LABEL_TITLE_SIZE = %s\n",LABEL_TITLE_SIZE);
        LogPrintf("LABEL_KV_SIZE = %s\n",LABEL_KV_SIZE);

    }

    m_timer = new QTimer(this);
    connect(m_timer, &QTimer::timeout, this, &MempoolDetail::updateFeeTable);
    m_timer->start(1000);
}

void MempoolDetail::setPlatformStyle(const PlatformStyle* platform_style)
{
    m_platform_style = platform_style;

    m_temp_widget = new QWidget(this);
    m_temp_widget->setFixedSize(QSize(100, 22)); // Adjust size as needed to match original button area

    m_top_layout = new QHBoxLayout();
    m_top_layout->addStretch();
    m_top_layout->addWidget(m_temp_widget);

    m_fee_table_model = new MempoolFeeTableModel(this);
    m_fee_table = new QTableView(this);
    m_fee_table->setModel(m_fee_table_model);

    m_fee_table->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    m_fee_table->setVerticalScrollBarPolicy(Qt::ScrollBarAlwaysOff);

    m_fee_table->setEditTriggers(QAbstractItemView::NoEditTriggers);
    m_fee_table->setSelectionBehavior(QAbstractItemView::SelectRows);
    m_fee_table->setSelectionMode(QAbstractItemView::SingleSelection);
    m_fee_table->setAlternatingRowColors(false);
    m_fee_table->setStyleSheet("");
    m_fee_table->setSortingEnabled(true);
    m_fee_table->horizontalHeader()->setStretchLastSection(true);
    m_fee_table->verticalHeader()->setVisible(true);
    m_fee_table->sortByColumn(m_fee_table_model->m_sort_column, m_fee_table_model->m_sort_order);

    // Right panel for transactions
    m_right_panel = new QWidget(this);
    QVBoxLayout* right_layout = new QVBoxLayout(m_right_panel);
    right_layout->setContentsMargins(0, 0, 0, 0);
    m_transaction_table = new QTableView(m_right_panel);
    m_transaction_model = new QStandardItemModel(this);
    m_transaction_table->setModel(m_transaction_model);
    m_transaction_table->setEditTriggers(QAbstractItemView::NoEditTriggers);
    m_transaction_table->setSelectionBehavior(QAbstractItemView::SelectRows);
    m_transaction_table->setSelectionMode(QAbstractItemView::SingleSelection);
    m_transaction_table->setSortingEnabled(true);
    m_transaction_model->setHorizontalHeaderLabels({"TXID", "Size", "Fee (sats)", "Fee Rate (sats/vB)"});
    m_transaction_table->horizontalHeader()->setStretchLastSection(true);
    right_layout->addWidget(m_transaction_table);
    m_right_panel->hide();
    right_layout->addWidget(m_transaction_table);
    m_right_panel->hide();

    QSplitter* splitter = new QSplitter(Qt::Horizontal, this);
    splitter->addWidget(m_fee_table);
    splitter->addWidget(m_right_panel);
    splitter->setSizes({width() / 2, width() / 2});

    QVBoxLayout* main_layout = new QVBoxLayout(this);
    main_layout->addLayout(m_top_layout);
    main_layout->addWidget(splitter);
    setLayout(main_layout);

    connect(m_fee_table, &QTableView::clicked, this, &MempoolDetail::updateFeeTable);

    connect(m_fee_table->selectionModel(), &QItemSelectionModel::currentRowChanged, this, [this](const QModelIndex &current, const QModelIndex &previous) {
        if (!current.isValid()) {
            m_selected_range = -1;
            m_right_panel->hide();
        }
        else {
            m_selected_range = m_fee_table_model->index(current.row(), 0).data(MempoolFeeTableModel::OriginalIndexRole).toInt();
            updateTransactionTable();
            m_right_panel->show();
        }
        if (m_clientmodel) {
            Q_EMIT m_clientmodel->mempoolRangeSelected(m_selected_range);
        }
        m_fee_table_model->setSelectedRange(m_selected_range);
    });
}

void MempoolDetail::updateTransactionTable()
{
    m_transaction_model->clear();
    if (!m_clientmodel || m_selected_range < 0) {
        return;
    }

    if (size_t(m_selected_range) >= MEMPOOL_FEE_RANGES_NUM) {
        return;
    }

    // MEMPOOL_FEE_RANGES are descending fee rates.
    // range 0: [MEMPOOL_FEE_RANGES[0], inf)
    // range i: [MEMPOOL_FEE_RANGES[i], MEMPOOL_FEE_RANGES[i-1])
    double min_fee_rate = MEMPOOL_FEE_RANGES[m_selected_range];
    double max_fee_rate = (m_selected_range > 0) ? MEMPOOL_FEE_RANGES[m_selected_range - 1] : std::numeric_limits<double>::max();

    auto mempool_info = m_clientmodel->node().getMempoolInfo();
    if (!mempool_info) return;

    for (const auto& tx_info : mempool_info->m_txs) {
        double fee_rate = (double)tx_info->fee.GetSatoshis() / tx_info->vsize;
        if (fee_rate >= min_fee_rate && fee_rate < max_fee_rate) {
            QList<QStandardItem *> rowItems;
            rowItems << new QStandardItem(QString::fromStdString(tx_info->txid.ToString()));
            rowItems << new QStandardItem(QString::number(tx_info->vsize));
            rowItems << new QStandardItem(GUIUtil::formatAmount(tx_info->fee, false, GUIUtil::separatorAlways));
            rowItems << new QStandardItem(QString::number(fee_rate, 'f', 2));
            m_transaction_model->appendRow(rowItems);
        }
    }
}

void MempoolDetail::setClientModel(ClientModel *model)

{

    m_clientmodel = model;

    if (model) {

        connect(model, &ClientModel::mempoolFeeHistChanged, this, &MempoolDetail::updateFeeTable);

        connect(model, &ClientModel::mempoolRangeSelected, this, &MempoolDetail::onRangeSelected);

        MempoolDetail::updateFeeTable();

    }

}



void MempoolDetail::updateFeeTable()

{

    if (m_clientmodel) {

        QMutexLocker locker(&m_clientmodel->m_mempool_locker);

        if (!m_clientmodel->m_mempool_feehist.empty()) {

            int selected_row = m_fee_table->selectionModel()->currentIndex().row();

            m_fee_table_model->updateModel(m_clientmodel->m_mempool_feehist[0].second);

            QSignalBlocker blocker(m_fee_table->selectionModel());

            if (selected_row >= 0 && selected_row < m_fee_table->model()->rowCount()) {

                m_fee_table->selectRow(selected_row);

            }

        }

    }

}



void MempoolDetail::setFontSize(qreal newSize)

{

    if (newSize < FONT_RANGE.width() || newSize > FONT_RANGE.height())

        return;



    m_font_size = newSize;



    QSettings settings;

    settings.setValue(mempoolDetailFontSizeKey, m_font_size);



    if (m_clientmodel) {

    }

}



void MempoolDetail::onRangeSelected(int range)
{
    QSignalBlocker blocker(m_fee_table->selectionModel());
    int row_to_select = -1;
    for (int i = 0; i < m_fee_table_model->rowCount(); ++i) {
        if (m_fee_table_model->index(i, 0).data(MempoolFeeTableModel::OriginalIndexRole).toInt() == range) {
            row_to_select = i;
            break;
        }
    }

    if (row_to_select != -1) {
        m_fee_table->selectRow(row_to_select);
    } else {
        m_fee_table->clearSelection();
    }
    m_fee_table_model->setSelectedRange(range);
}



void MempoolDetail::mousePressEvent(QMouseEvent *event) { Q_EMIT objectClicked(this);



        }



    



        updateFeeTable();



    



    }

void MempoolDetail::mouseReleaseEvent(QMouseEvent *event) { Q_EMIT objectClicked(this);



    QWidget::mouseReleaseEvent(event);

    if (MEMPOOL_GRAPH_LOGGING){

        LogPrintf("mousePressEvent\n");

        LogPrintf("event->pos().x() %s\n",event->pos().x());

        LogPrintf("event->pos().y() %s\n",event->pos().y());

        LogPrintf("event->type() %s\n",event->type());

        LogPrintf("event->type() %s\n",event->type());

}
}

void MempoolDetail::mouseDoubleClickEvent(QMouseEvent *event) { Q_EMIT objectClicked(this);



        QWidget::mouseDoubleClickEvent(event);



        if (MEMPOOL_GRAPH_LOGGING){



            LogPrintf("mousePressEvent\n");



            LogPrintf("event->pos().x() %s\n",event->pos().x());



            LogPrintf("event->pos().y() %s\n",event->pos().y());



        }



    



        updateFeeTable();



    



    }

void MempoolDetail::mouseMoveEvent(QMouseEvent *event) { Q_EMIT objectClicked(this);



    QWidget::mouseMoveEvent(event);

    if (MEMPOOL_GRAPH_LOGGING){

        LogPrintf("mousePressEvent\n");

        LogPrintf("event->pos().x() %s\n",event->pos().x());

        LogPrintf("event->pos().y() %s\n",event->pos().y());

    }

}



void MempoolDetail::enterEvent(QEnterEvent *event) { Q_EMIT objectClicked(this);



    QEvent *this_event = event;

    if (MEMPOOL_GRAPH_LOGGING){

        LogPrintf("enterEvent\n");

        LogPrintf("this_event->type() %s\n",this_event->type());

        LogPrintf("this_event->type() %s\n",this_event->type());

            }

        

            updateFeeTable();

            showFeeRanges(this_event);

            showFeeRects(this_event);

        

        }



void MempoolDetail::leaveEvent(QEvent *event) { Q_EMIT objectClicked(this);



    QEvent *this_event = event;

    if (MEMPOOL_GRAPH_LOGGING){

        LogPrintf("leaveEvent\n");

        LogPrintf("this_event->type() %s\n",this_event->type());

        LogPrintf("this_event->type() %s\n",this_event->type());

    }



    hideFeeRanges(this_event);

    hideFeeRects(this_event);



}



void MempoolDetail::changeEvent(QEvent* e)

{

    // No buttons to update on palette change anymore

    QWidget::changeEvent(e);

}



void MempoolDetail::showFeeRanges(QEvent *event){







    QEvent *this_event = event;







    if (MEMPOOL_GRAPH_LOGGING){







        LogPrintf("leaveEvent\n");







        LogPrintf("this_event->type() %s\n",this_event->type());







        LogPrintf("this_event->type() %s\n",this_event->type());







    }



    updateFeeTable();







};
void MempoolDetail::hideFeeRanges(QEvent *event){
    QEvent *this_event = event;
    if (MEMPOOL_GRAPH_LOGGING){
        LogPrintf("leaveEvent\n");
        LogPrintf("this_event->type() %s\n",this_event->type());
        LogPrintf("this_event->type() %s\n",this_event->type());
    }
    updateFeeTable();

};

void MempoolDetail::showFeeRects(QEvent *event){

    QEvent *this_event = event;
    if (MEMPOOL_GRAPH_LOGGING){
        LogPrintf("leaveEvent\n");
        LogPrintf("this_event->type() %s\n",this_event->type());
        LogPrintf("this_event->type() %s\n",this_event->type());
    }
    updateFeeTable();

};
void MempoolDetail::hideFeeRects(QEvent *event){

    QEvent *this_event = event;
    if (MEMPOOL_GRAPH_LOGGING){
        LogPrintf("leaveEvent\n");
        LogPrintf("this_event->type() %s\n",this_event->type());
        LogPrintf("this_event->type() %s\n",this_event->type());
    }

};
