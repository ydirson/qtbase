// Copyright (C) 2016 The Qt Company Ltd.
// SPDX-License-Identifier: LicenseRef-Qt-Commercial OR LGPL-3.0-only OR GPL-2.0-only OR GPL-3.0-only

#include <AppKit/AppKit.h>

#include "qmacclipboard.h"
#include <QtGui/qclipboard.h>
#include <QtGui/qguiapplication.h>
#include <QtGui/qbitmap.h>
#include <QtCore/qdatetime.h>
#include <QtCore/qdebug.h>
#include <QtCore/private/qcore_mac_p.h>
#include <QtGui/qguiapplication.h>
#include <QtGui/qevent.h>
#include <QtCore/qurl.h>
#include <stdlib.h>
#include <string.h>
#include "qcocoahelpers.h"
#include <type_traits>

QT_BEGIN_NAMESPACE

using namespace Qt::StringLiterals;

/*****************************************************************************
   QMacPasteboard code
*****************************************************************************/

namespace
{
OSStatus PasteboardGetItemCountSafe(PasteboardRef paste, ItemCount *cnt)
{
    Q_ASSERT(paste);
    Q_ASSERT(cnt);
    const OSStatus result = PasteboardGetItemCount(paste, cnt);
    // Despite being declared unsigned, this API can return -1
    if (std::make_signed<ItemCount>::type(*cnt) < 0)
        *cnt = 0;
    return result;
}
} // namespace

// Ensure we don't call the broken one later on
#define PasteboardGetItemCount

class QMacMimeData : public QMimeData
{
public:
    QVariant variantData(const QString &mime) { return retrieveData(mime, QMetaType()); }
private:
    QMacMimeData();
};

QMacPasteboard::Promise::Promise(int itemId, QMacInternalPasteboardMime *c, QString m, QMacMimeData *md, int o, DataRequestType drt)
    : itemId(itemId), offset(o), convertor(c), mime(m), dataRequestType(drt)
{
    // Request the data from the application immediately for eager requests.
    if (dataRequestType == QMacPasteboard::EagerRequest) {
        variantData = md->variantData(m);
        mimeData = nullptr;
    } else {
        mimeData = md;
    }
}

QMacPasteboard::QMacPasteboard(PasteboardRef p, uchar mt)
{
    mac_mime_source = false;
    mime_type = mt ? mt : uchar(QMacInternalPasteboardMime::MIME_ALL);
    paste = p;
    CFRetain(paste);
    resolvingBeforeDestruction = false;
}

QMacPasteboard::QMacPasteboard(uchar mt)
{
    mac_mime_source = false;
    mime_type = mt ? mt : uchar(QMacInternalPasteboardMime::MIME_ALL);
    paste = nullptr;
    OSStatus err = PasteboardCreate(nullptr, &paste);
    if (err == noErr) {
        PasteboardSetPromiseKeeper(paste, promiseKeeper, this);
    } else {
        qDebug("PasteBoard: Error creating pasteboard: [%d]", (int)err);
    }
    resolvingBeforeDestruction = false;
}

QMacPasteboard::QMacPasteboard(CFStringRef name, uchar mt)
{
    mac_mime_source = false;
    mime_type = mt ? mt : uchar(QMacInternalPasteboardMime::MIME_ALL);
    paste = nullptr;
    OSStatus err = PasteboardCreate(name, &paste);
    if (err == noErr) {
        PasteboardSetPromiseKeeper(paste, promiseKeeper, this);
    } else {
        qDebug("PasteBoard: Error creating pasteboard: %s [%d]", QString::fromCFString(name).toLatin1().constData(), (int)err);
    }
    resolvingBeforeDestruction = false;
}

QMacPasteboard::~QMacPasteboard()
{
    /*
        Commit all promises for paste when shutting down,
        unless we are the stack-allocated clipboard used by QCocoaDrag.
    */
    if (mime_type == QMacInternalPasteboardMime::MIME_DND)
        resolvingBeforeDestruction = true;
    PasteboardResolvePromises(paste);
    if (paste)
        CFRelease(paste);
}

PasteboardRef
QMacPasteboard::pasteBoard() const
{
    return paste;
}

OSStatus QMacPasteboard::promiseKeeper(PasteboardRef paste, PasteboardItemID id, CFStringRef flavor, void *_qpaste)
{
    QMacPasteboard *qpaste = (QMacPasteboard*)_qpaste;
    const long promise_id = (long)id;

    // Find the kept promise
    QList<QMacInternalPasteboardMime*> availableConverters
        = QMacInternalPasteboardMime::all(QMacInternalPasteboardMime::MIME_ALL);
    const QString flavorAsQString = QString::fromCFString(flavor);
    QMacPasteboard::Promise promise;
    for (int i = 0; i < qpaste->promises.size(); i++){
        QMacPasteboard::Promise tmp = qpaste->promises[i];
        if (!availableConverters.contains(tmp.convertor)) {
            // promise.converter is a pointer initialized by the value found
            // in QMacInternalPasteboardMime's global list of QMacInternalPasteboardMimes.
            // We add pointers to this list in QMacInternalPasteboardMime's ctor;
            // we remove these pointers in QMacInternalPasteboardMime's dtor.
            // If tmp.converter was not found in this list, we probably have a
            // dangling pointer so let's skip it.
            continue;
        }

        if (tmp.itemId == promise_id && tmp.convertor->canConvert(tmp.mime, flavorAsQString)){
            promise = tmp;
            break;
        }
    }

    if (!promise.itemId && flavorAsQString == "com.trolltech.qt.MimeTypeName"_L1) {
        // we have promised this data, but won't be able to convert, so return null data.
        // This helps in making the application/x-qt-mime-type-name hidden from normal use.
        QByteArray ba;
        QCFType<CFDataRef> data = CFDataCreate(nullptr, (UInt8*)ba.constData(), ba.size());
        PasteboardPutItemFlavor(paste, id, flavor, data, kPasteboardFlavorNoFlags);
        return noErr;
    }

    if (!promise.itemId) {
        // There was no promise that could deliver data for the
        // given id and flavor. This should not happen.
        qDebug("Pasteboard: %d: Request for %ld, %s, but no promise found!", __LINE__, promise_id, qPrintable(flavorAsQString));
        return cantGetFlavorErr;
    }

    qCDebug(lcQpaClipboard, "PasteBoard: Calling in promise for %s[%ld] [%s] (%s) [%d]", qPrintable(promise.mime), promise_id,
           qPrintable(flavorAsQString), qPrintable(promise.convertor->convertorName()), promise.offset);

    // Get the promise data. If this is a "lazy" promise call variantData()
    // to request the data from the application.
    QVariant promiseData;
    if (promise.dataRequestType == LazyRequest) {
        if (!qpaste->resolvingBeforeDestruction && !promise.mimeData.isNull())
            promiseData = promise.mimeData->variantData(promise.mime);
    } else {
        promiseData = promise.variantData;
    }

    QList<QByteArray> md = promise.convertor->convertFromMime(promise.mime, promiseData, flavorAsQString);
    if (md.size() <= promise.offset)
        return cantGetFlavorErr;
    const QByteArray &ba = md[promise.offset];
    QCFType<CFDataRef> data = CFDataCreate(nullptr, (UInt8*)ba.constData(), ba.size());
    PasteboardPutItemFlavor(paste, id, flavor, data, kPasteboardFlavorNoFlags);
    return noErr;
}

bool
QMacPasteboard::hasOSType(int c_flavor) const
{
    if (!paste)
        return false;

    sync();

    ItemCount cnt = 0;
    if (PasteboardGetItemCountSafe(paste, &cnt) || !cnt)
        return false;

    qCDebug(lcQpaClipboard, "PasteBoard: hasOSType [%c%c%c%c]", (c_flavor>>24)&0xFF, (c_flavor>>16)&0xFF,
           (c_flavor>>8)&0xFF, (c_flavor>>0)&0xFF);
    for (uint index = 1; index <= cnt; ++index) {

        PasteboardItemID id;
        if (PasteboardGetItemIdentifier(paste, index, &id) != noErr)
            return false;

        QCFType<CFArrayRef> types;
        if (PasteboardCopyItemFlavors(paste, id, &types ) != noErr)
            return false;

        const int type_count = CFArrayGetCount(types);
        for (int i = 0; i < type_count; ++i) {
            CFStringRef flavor = (CFStringRef)CFArrayGetValueAtIndex(types, i);
            CFStringRef preferredTag = UTTypeCopyPreferredTagWithClass(flavor, kUTTagClassOSType);
            const int os_flavor = UTGetOSTypeFromString(preferredTag);
            if (preferredTag)
                CFRelease(preferredTag);
            if (os_flavor == c_flavor) {
                qCDebug(lcQpaClipboard, "  - Found!");
                return true;
            }
        }
    }
    qCDebug(lcQpaClipboard, "  - NotFound!");
    return false;
}

bool
QMacPasteboard::hasFlavor(QString c_flavor) const
{
    if (!paste)
        return false;

    sync();

    ItemCount cnt = 0;
    if (PasteboardGetItemCountSafe(paste, &cnt) || !cnt)
        return false;

    qCDebug(lcQpaClipboard, "PasteBoard: hasFlavor [%s]", qPrintable(c_flavor));
    for (uint index = 1; index <= cnt; ++index) {

        PasteboardItemID id;
        if (PasteboardGetItemIdentifier(paste, index, &id) != noErr)
            return false;

        PasteboardFlavorFlags flags;
        if (PasteboardGetItemFlavorFlags(paste, id, QCFString(c_flavor), &flags) == noErr) {
            qCDebug(lcQpaClipboard, "  - Found!");
            return true;
        }
    }
    qCDebug(lcQpaClipboard, "  - NotFound!");
    return false;
}

class QMacPasteboardMimeSource : public QMimeData {
    const QMacPasteboard *paste;
public:
    QMacPasteboardMimeSource(const QMacPasteboard *p) : QMimeData(), paste(p) { }
    ~QMacPasteboardMimeSource() { }
    virtual QStringList formats() const { return paste->formats(); }
    virtual QVariant retrieveData(const QString &format, QMetaType type) const { return paste->retrieveData(format, type); }
};

QMimeData
*QMacPasteboard::mimeData() const
{
    if (!mime) {
        mac_mime_source = true;
        mime = new QMacPasteboardMimeSource(this);

    }
    return mime;
}

void
QMacPasteboard::setMimeData(QMimeData *mime_src, DataRequestType dataRequestType)
{
    if (!paste)
        return;

    if (mime == mime_src || (!mime_src && mime && mac_mime_source))
        return;
    mac_mime_source = false;
    delete mime;
    mime = mime_src;

    QList<QMacInternalPasteboardMime*> availableConverters = QMacInternalPasteboardMime::all(mime_type);
    if (mime != nullptr) {
        clear_helper();
        QStringList formats = mime_src->formats();

        // QMimeData sub classes reimplementing the formats() might not expose the
        // temporary "application/x-qt-mime-type-name" mimetype. So check the existence
        // of this mime type while doing drag and drop.
        QString dummyMimeType("application/x-qt-mime-type-name"_L1);
        if (!formats.contains(dummyMimeType)) {
            QByteArray dummyType = mime_src->data(dummyMimeType);
            if (!dummyType.isEmpty()) {
                formats.append(dummyMimeType);
            }
        }
        for (int f = 0; f < formats.size(); ++f) {
            QString mimeType = formats.at(f);
            for (QList<QMacInternalPasteboardMime *>::Iterator it = availableConverters.begin(); it != availableConverters.end(); ++it) {
                QMacInternalPasteboardMime *c = (*it);
                // Hack: The Rtf handler converts incoming Rtf to Html. We do
                // not want to convert outgoing Html to Rtf but instead keep
                // posting it as Html. Skip the Rtf handler here.
                if (c->convertorName() == "Rtf"_L1)
                    continue;
                QString flavor(c->flavorFor(mimeType));
                if (!flavor.isEmpty()) {
                    QMacMimeData *mimeData = static_cast<QMacMimeData*>(mime_src);

                    int numItems = c->count(mime_src);
                    for (int item = 0; item < numItems; ++item) {
                        const NSInteger itemID = item+1; //id starts at 1
                        //QMacPasteboard::Promise promise = (dataRequestType == QMacPasteboard::EagerRequest) ?
                        //    QMacPasteboard::Promise::eagerPromise(itemID, c, mimeType, mimeData, item) :
                        //    QMacPasteboard::Promise::lazyPromise(itemID, c, mimeType, mimeData, item);

                        QMacPasteboard::Promise promise(itemID, c, mimeType, mimeData, item, dataRequestType);
                        promises.append(promise);
                        PasteboardPutItemFlavor(paste, reinterpret_cast<PasteboardItemID>(itemID), QCFString(flavor), 0, kPasteboardFlavorNoFlags);
                        qCDebug(lcQpaClipboard, " -  adding %ld %s [%s] <%s> [%d]",
                               itemID, qPrintable(mimeType), qPrintable(flavor), qPrintable(c->convertorName()), item);
                    }
                }
            }
        }
    }
}

QStringList
QMacPasteboard::formats() const
{
    if (!paste)
        return QStringList();

    sync();

    QStringList ret;
    ItemCount cnt = 0;
    if (PasteboardGetItemCountSafe(paste, &cnt) || !cnt)
        return ret;

    qCDebug(lcQpaClipboard, "PasteBoard: Formats [%d]", (int)cnt);
    for (uint index = 1; index <= cnt; ++index) {

        PasteboardItemID id;
        if (PasteboardGetItemIdentifier(paste, index, &id) != noErr)
            continue;

        QCFType<CFArrayRef> types;
        if (PasteboardCopyItemFlavors(paste, id, &types ) != noErr)
            continue;

        const int type_count = CFArrayGetCount(types);
        for (int i = 0; i < type_count; ++i) {
            const QString flavor = QString::fromCFString((CFStringRef)CFArrayGetValueAtIndex(types, i));
            qCDebug(lcQpaClipboard, " -%s", qPrintable(QString(flavor)));
            QString mimeType = QMacInternalPasteboardMime::flavorToMime(mime_type, flavor);
            if (!mimeType.isEmpty() && !ret.contains(mimeType)) {
                qCDebug(lcQpaClipboard, "   -<%lld> %s [%s]", ret.size(), qPrintable(mimeType), qPrintable(QString(flavor)));
                ret << mimeType;
            }
        }
    }
    return ret;
}

bool
QMacPasteboard::hasFormat(const QString &format) const
{
    if (!paste)
        return false;

    sync();

    ItemCount cnt = 0;
    if (PasteboardGetItemCountSafe(paste, &cnt) || !cnt)
        return false;

    qCDebug(lcQpaClipboard, "PasteBoard: hasFormat [%s]", qPrintable(format));
    for (uint index = 1; index <= cnt; ++index) {

        PasteboardItemID id;
        if (PasteboardGetItemIdentifier(paste, index, &id) != noErr)
            continue;

        QCFType<CFArrayRef> types;
        if (PasteboardCopyItemFlavors(paste, id, &types ) != noErr)
            continue;

        const int type_count = CFArrayGetCount(types);
        for (int i = 0; i < type_count; ++i) {
            const QString flavor = QString::fromCFString((CFStringRef)CFArrayGetValueAtIndex(types, i));
            qCDebug(lcQpaClipboard, " -%s [0x%x]", qPrintable(QString(flavor)), mime_type);
            QString mimeType = QMacInternalPasteboardMime::flavorToMime(mime_type, flavor);
            if (!mimeType.isEmpty())
                qCDebug(lcQpaClipboard, "   - %s", qPrintable(mimeType));
            if (mimeType == format)
                return true;
        }
    }
    return false;
}

QVariant
QMacPasteboard::retrieveData(const QString &format, QMetaType) const
{
    if (!paste)
        return QVariant();

    sync();

    ItemCount cnt = 0;
    if (PasteboardGetItemCountSafe(paste, &cnt) || !cnt)
        return QByteArray();

    qCDebug(lcQpaClipboard, "Pasteboard: retrieveData [%s]", qPrintable(format));
    const QList<QMacInternalPasteboardMime *> mimes = QMacInternalPasteboardMime::all(mime_type);
    for (int mime = 0; mime < mimes.size(); ++mime) {
        QMacInternalPasteboardMime *c = mimes.at(mime);
        QString c_flavor = c->flavorFor(format);
        if (!c_flavor.isEmpty()) {
            // Converting via PasteboardCopyItemFlavorData below will for some UITs result
            // in newlines mapping to '\r' instead of '\n'. To work around this we shortcut
            // the conversion via NSPasteboard's NSStringPboardType if possible.
            if (c_flavor == "com.apple.traditional-mac-plain-text"_L1
             || c_flavor == "public.utf8-plain-text"_L1
             || c_flavor == "public.utf16-plain-text"_L1) {
                QString str = qt_mac_get_pasteboardString(paste);
                if (!str.isEmpty())
                    return str;
            }

            QVariant ret;
            QList<QByteArray> retList;
            for (uint index = 1; index <= cnt; ++index) {
                PasteboardItemID id;
                if (PasteboardGetItemIdentifier(paste, index, &id) != noErr)
                    continue;

                QCFType<CFArrayRef> types;
                if (PasteboardCopyItemFlavors(paste, id, &types ) != noErr)
                    continue;

                const int type_count = CFArrayGetCount(types);
                for (int i = 0; i < type_count; ++i) {
                    CFStringRef flavor = static_cast<CFStringRef>(CFArrayGetValueAtIndex(types, i));
                    if (c_flavor == QString::fromCFString(flavor)) {
                        QCFType<CFDataRef> macBuffer;
                        if (PasteboardCopyItemFlavorData(paste, id, flavor, &macBuffer) == noErr) {
                            QByteArray buffer((const char *)CFDataGetBytePtr(macBuffer), CFDataGetLength(macBuffer));
                            if (!buffer.isEmpty()) {
                                qCDebug(lcQpaClipboard, "  - %s [%s] (%s)", qPrintable(format), qPrintable(c_flavor), qPrintable(c->convertorName()));
                                buffer.detach(); //detach since we release the macBuffer
                                retList.append(buffer);
                                break; //skip to next element
                            }
                        }
                    } else {
                        qCDebug(lcQpaClipboard, "  - NoMatch %s [%s] (%s)", qPrintable(c_flavor), qPrintable(QString::fromCFString(flavor)), qPrintable(c->convertorName()));
                    }
                }
            }

            if (!retList.isEmpty()) {
                ret = c->convertToMime(format, retList, c_flavor);
                return ret;
            }
        }
    }
    return QVariant();
}

void QMacPasteboard::clear_helper()
{
    if (paste)
        PasteboardClear(paste);
    promises.clear();
}

void
QMacPasteboard::clear()
{
    qCDebug(lcQpaClipboard, "PasteBoard: clear!");
    clear_helper();
}

bool
QMacPasteboard::sync() const
{
    if (!paste)
        return false;
    const bool fromGlobal = PasteboardSynchronize(paste) & kPasteboardModified;

    if (fromGlobal)
        const_cast<QMacPasteboard *>(this)->setMimeData(nullptr);

    if (fromGlobal)
        qCDebug(lcQpaClipboard, "Pasteboard: Synchronize!");
    return fromGlobal;
}


QString qt_mac_get_pasteboardString(PasteboardRef paste)
{
    QMacAutoReleasePool pool;
    NSPasteboard *pb = nil;
    CFStringRef pbname;
    if (PasteboardCopyName(paste, &pbname) == noErr) {
        pb = [NSPasteboard pasteboardWithName:const_cast<NSString *>(reinterpret_cast<const NSString *>(pbname))];
        CFRelease(pbname);
    } else {
        pb = [NSPasteboard generalPasteboard];
    }
    if (pb) {
        NSString *text = [pb stringForType:NSPasteboardTypeString];
        if (text)
            return QString::fromNSString(text);
    }
    return QString();
}

QT_END_NAMESPACE
