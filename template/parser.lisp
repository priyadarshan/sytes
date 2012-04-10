(in-package #:sytes.template)

(defparameter *token-start* #\{)
(defparameter *token-stop* #\})

(defun parse (input &key (template-name "UNKNOWN-TEMPLATE") (context *current-context*))
  (let ((line 1)
        (col 0)
        (tokline 0)
        (tokcol 0)
        (indentation 0)
        (past-indent nil)
        (in-qq 0))
    (labels
        ((croak (msg &rest args)
           (error "Error in ~A (~A,~A): ~A" template-name tokline tokcol
                  (apply #'format nil msg args)))

         (peek (&optional eof-error-p)
           (peek-char nil input eof-error-p))

         (next (&optional eof-error-p)
           (let ((ch (read-char input eof-error-p)))
             (cond
               ((eql ch #\Newline)
                (setf line (1+ line)
                      col 0
                      indentation 0
                      past-indent nil))
               (ch
                (incf col)
                (unless past-indent
                  (if (eql ch #\Space)
                      (incf indentation)
                      (setq past-indent t)))))
             ch))

         (read-while (pred &optional eof-error-p)
           (with-output-to-string (ret)
             (loop while (funcall pred (peek eof-error-p))
                do (write-char (next) ret))))

         (skip-whitespace ()
           (read-while (lambda (ch)
                         (member ch '(#\Space
                                      #\Newline
                                      #\Tab
                                      #\Page
                                      #\Line_Separator
                                      #\Paragraph_Separator
                                      #\NO-BREAK_SPACE)))))

         (skip (ch)
           (unless (char= (next) ch)
             (croak "Expecting '~C'" ch)))

         (read-string ()
           (skip #\")
           (with-output-to-string (ret)
             (loop for ch = (next)
                with escaped = nil
                do (cond
                     ((not ch) (croak "Unterminated string literal"))
                     (escaped (write-char ch ret)
                              (setf escaped nil))
                     ((char= ch #\\) (setf escaped t))
                     ((char= ch #\") (return))
                     (t (write-char ch ret))))))

         (read-symbol-chunk ()
           (let ((sym (read-while (lambda (ch)
                                    (when ch
                                      (not (member ch '(#\( #\) #\[ #\] #\` #\' #\, #\{ #\} #\\ #\|
                                                        #\Space
                                                        #\Newline
                                                        #\Tab
                                                        #\Page
                                                        #\Line_Separator
                                                        #\Paragraph_Separator
                                                        #\NO-BREAK_SPACE))))))))
             (when (zerop (length sym))
               (croak "Apparently can't deal with character ~A" (peek)))
             sym))

         (read-symbol ()
           (let ((sym (read-symbol-chunk)))
             (handler-case
                 (parse-number:parse-number sym)
               (error ()
                 ;; handle dot syntax
                 (let ((path (split-sequence:split-sequence #\. sym)))
                   (if (cdr path)
                       `(,(tops "%dot-lookup")
                          ,(my-symbol-in-context (car path) context)
                          ,@(mapcar (lambda (x)
                                      (list (tops "quote")
                                            (my-symbol-in-context x context)))
                                    (cdr path)))
                       (my-symbol-in-context sym context)))))))

         (skip-comment ()
           (skip #\;)
           (read-while (lambda (ch)
                         (and ch (not (member ch '(#\Newline #\Line_Separator #\Linefeed)))))))

         (read-list (&optional (end-char #\)))
           (skip #\()
           (loop with ret = nil with p = nil
              do (skip-whitespace)
              (let ((ch (peek)))
                (unless ch (croak "Unterminated list"))
                (cond
                  ((char= ch #\;)
                   (skip-comment))
                  ((char= ch end-char)
                   (next) (return ret))
                  ((char= ch #\.)
                   (next)
                   (setf (cdr p) (read-token))
                   (skip-whitespace)
                   (skip end-char)
                   (return ret))
                  (t
                   (let ((cell (list (read-token))))
                     (if p
                         (setf (cdr p) cell)
                         (setf ret cell))
                     (setf p cell)))))))

         (read-quote ()
           (skip #\')
           (list (tops "quote") (read-token)))

         (read-qq ()
           (skip #\`)
           (incf in-qq)
           (unwind-protect
                (list (tops "quasiquote") (read-token))
             (decf in-qq)))

         (read-comma ()
           (skip #\,)
           (when (zerop in-qq)
             (croak "Comma outside quasiquote"))
           (cond
             ((char= (peek) #\@)
              (next)
              (list (tops "splice") (read-token)))
             (t
              (list (tops "unquote") (read-token)))))

         (read-token ()
           (skip-whitespace)
           (setf tokline line
                 tokcol col)
           (let ((ch (peek)))
             (cond
               ((char= ch *token-start*)
                (next)
                (prog1
                    (list* (tops "progn") (read-text))
                  (skip *token-stop*)))
               ((char= ch #\;) (skip-comment) (read-token))
               ((char= ch #\") (read-string))
               ((char= ch #\() (read-list #\)))
               ((char= ch #\[) (read-list #\]))
               ((char= ch #\') (read-quote))
               ((char= ch #\`) (read-qq))
               ((char= ch #\,) (read-comma))
               (ch (read-symbol)))))

         (read-text-chunk ()
           (setf tokline line
                 tokcol col)
           (with-output-to-string (ret)
             (loop for ch = (peek)
                do (cond
                     ((not ch) (return ret))
                     ((char= ch #\\)
                      (next)
                      (let ((ch (peek)))
                        (cond
                          ((eql ch *token-start*)
                           (next) (write-char *token-start* ret))
                          ((eql ch *token-stop*)
                           (next) (write-char *token-stop* ret))
                          ((and (eql ch #\;) (= col 1))
                           (next) (write-char #\; ret))
                          ((member ch '(#\Newline #\Linefeed #\Line_Separator))
                           (next))
                          (t (write-char #\\ ret)))))
                     ((char= ch *token-start*) (return ret))
                     ((char= ch *token-stop*) (return ret))
                     ((and (char= ch #\;) (= col 0))
                      (skip-comment)
                      (next))
                     (t (write-char (next) ret))))))

         (read-text ()
           (loop for ch = (peek) with ret = '()
              do (cond
                   ((not ch) (return (nreverse ret)))
                   ((char= ch *token-start*)
                    (next)
                    (skip-whitespace)
                    (unless (char= (peek) *token-stop*)
                      (let ((tok (read-token)))
                        (skip-whitespace)
                        (when (char= (peek) #\|)
                          (next)
                          (let ((filters (loop until (char= (peek) *token-stop*)
                                            unless (peek) do (croak "Expecting '~C'" *token-stop*)
                                            collect (read-token))))
                            (setf tok (list* (tops "filter") tok filters))))
                        (push (list (tops "echo-esc") tok) ret)))
                    (skip-whitespace)
                    (skip *token-stop*))
                   ((char= ch *token-stop*)
                    (return (nreverse ret)))
                   (t
                    (push (list (tops "echo-raw") (read-text-chunk)) ret))))))

      (list* (tops "progn") (read-text)))))