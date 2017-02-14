(in-package #:cl-user)

(defpackage #:vlime-sbcl
  (:use #:cl
        #:aio-sbcl
        #:vlime-protocol
        #:vlime-connection)
  (:export #:main
           #:main-threaded))

(in-package #:vlime-sbcl)


(defparameter +cr-lf+ (format nil "~c~c" #\return #\linefeed))
(defparameter +cr+ (format nil "~c" #\return))
(defparameter +lf+ (format nil "~c" #\linefeed))


(defvar *read-buffer-map* nil)


(defun socket-error-cb (afd condition)
  (declare (ignore afd))
  (handler-case (error condition)
    (aio-error ()
      (let* ((afd (aio-error-afd condition))
             (conn (lookup-connection afd)))
        (aio-fd-close afd)
        (aio-fd-close (connection-socket (connection-peer conn)))
        (connection-close conn)
        (vom:debug "Connection count: ~s" (count-connections))))
    (error ()
      (vom:debug "Socket event: ~a" condition))))


(defun client-connect-cb (afd)
  (unless (lookup-connection afd)
    (make-connection :socket afd)
    (vom:debug "New connection from ~s" afd)
    (vom:debug "Connection count: ~s" (count-connections)))
  (aio-fd-disable-write-handle afd :clear-cb t))


(defun swank-read-cb (afd data)
  (let ((swank-conn (lookup-connection afd)))
    (multiple-value-bind (msg-list buffered)
                         (parse-swank-msg
                           data (gethash afd *read-buffer-map* #()))
      (setf (gethash afd *read-buffer-map*) buffered)
      (when msg-list
        (dolist (msg msg-list)
          (vom:debug "Message from SWANK: ~s" msg)
          (aio-fd-write (connection-socket (connection-peer swank-conn))
                        (msg-swank-to-client msg :octets)))))))


(defun client-read-cb (afd data swank-host swank-port)
  (let ((client-conn (lookup-connection afd)))
    (multiple-value-bind (line-list buffered)
                         (parse-line
                           data (gethash afd *read-buffer-map* #()))
      (setf (gethash afd *read-buffer-map*) buffered)
      (when line-list
        (ensure-peer-connection
          client-conn
          #'(lambda ()
              (tcp-connect swank-host swank-port
                           :read-cb #'swank-read-cb
                           :error-cb #'socket-error-cb)))
        (dolist (line line-list)
          (vom:debug "Message from ~s: ~s" afd line)
          (when (and (string/= line +cr-lf+)
                     (string/= line +cr+)
                     (string/= line +lf+))
            (aio-fd-write (connection-socket (connection-peer client-conn))
                          (msg-client-to-swank line :octets))))))))


(in-package #:vlime)

(defmethod start-server ((backend (eql :sbcl)) host port swank-host swank-port)
  (vom:config t :debug)
  (setf vlime-connection:*connections* (make-hash-table))
  (setf aio-sbcl:*fd-map* (make-hash-table))
  (setf aio-sbcl:*static-buffer* (make-array 4096 :element-type '(unsigned-byte 8)))
  (setf vlime-sbcl::*read-buffer-map* (make-hash-table))

  (let ((server (aio-sbcl:tcp-server
                  host port
                  :client-read-cb #'(lambda (afd data)
                                      (vlime-sbcl::client-read-cb
                                        afd data
                                        swank-host swank-port))
                  :client-write-cb #'vlime-sbcl::client-connect-cb
                  :client-error-cb #'vlime-sbcl::socket-error-cb)))
    (vom:debug "Server created: ~s" server)
    server))