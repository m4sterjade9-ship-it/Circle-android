-- Run this if you already ran update18.sql earlier (or just want to be sure you are the staff account).
insert into support_staff(user_id)
  select id from auth.users where lower(email)=lower('m4sterjade9@gmail.com')
  on conflict do nothing;
select u.email, (s.user_id is not null) as is_staff
from auth.users u left join support_staff s on s.user_id=u.id
where lower(u.email)=lower('m4sterjade9@gmail.com');
